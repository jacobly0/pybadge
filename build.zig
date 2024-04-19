const std = @import("std");
const Build = std.Build;

const MicroZig = @import("microzig/build");
const MemoryRegion = @typeInfo(std.meta.FieldType(MicroZig.Chip, .memory_regions)).Pointer.child;
const atsam = @import("microzig/bsp/microchip/atsam");

pub fn getTarget(root: anytype) MicroZig.Target {
    return .{
        .preferred_format = .elf,
        .chip = atsam.chips.atsamd51j19.chip,
        .hal = .{
            .root_source_file = root.path("src/hal.zig"),
        },
        .board = .{
            .name = "SYCL Badge 2024",
            .root_source_file = root.path("src/board.zig"),
        },
    };
}

pub fn build(b: *Build) void {
    const sycl_badge_2024 = getTarget(b);

    const mz = MicroZig.init(b, .{});

    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("wasm4", .{ .root_source_file = b.path("src/wasm4.zig") });

    var dep: std.Build.Dependency = .{ .builder = b };
    const cart = add_cart(&dep, b, .{
        .name = "sample",
        .optimize = optimize,
        .root_source_file = b.path("samples/feature_test.zig"),
    });

    const watch_step = b.step("watch", "");
    watch_step.dependOn(&cart.watch_run_cmd.step);

    const modified_memory_regions = b.allocator.dupe(MemoryRegion, sycl_badge_2024.chip.memory_regions) catch @panic("out of memory");
    for (modified_memory_regions) |*memory_region| {
        if (memory_region.kind != .ram) continue;
        memory_region.offset += 0x19A0;
        memory_region.length -= 0x19A0;
        break;
    }
    var modified_sycl_badge_2024 = sycl_badge_2024;
    modified_sycl_badge_2024.chip.memory_regions = modified_memory_regions;

    const fw_options = b.addOptions();
    fw_options.addOption(bool, "have_cart", false);

    const fw = mz.add_firmware(b, .{
        .name = "badge-io",
        .target = modified_sycl_badge_2024,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });
    fw.artifact.step.dependOn(&fw_options.step);
    fw.add_app_import("options", fw_options.createModule(), .{});
    mz.install_firmware(b, fw, .{});
    mz.install_firmware(b, fw, .{ .format = .{ .uf2 = .SAMD51 } });

    const badge = mz.add_firmware(b, .{
        .name = "badge",
        .target = sycl_badge_2024,
        .optimize = optimize,
        .root_source_file = b.path("src/badge.zig"),
    });
    mz.install_firmware(b, badge, .{});

    for ([_][]const u8{
        "blinky",
        "blinky_timer",
        "usb_cdc",
        "usb_storage",
        "buttons",
        "lcd",
        "audio",
        "light_sensor",
        "neopixels",
        "qspi",
    }) |name| {
        const mvp = mz.add_firmware(b, .{
            .name = b.fmt("badge.demo.{s}", .{name}),
            .target = sycl_badge_2024,
            .optimize = optimize,
            .root_source_file = b.path(b.fmt("src/badge/demos/{s}.zig", .{name})),
        });
        mz.install_firmware(b, mvp, .{});
    }

    const font_export_step = b.step("generate-font.ts", "convert src/font.zig to simulator/src/font.ts");
    font_export_step.makeFn = struct {
        fn make(_: *std.Build.Step, _: *std.Progress.Node) anyerror!void {
            const font = @import("src/font.zig").font;
            var file = try std.fs.cwd().createFile("simulator/src/font.ts", .{});
            try file.writer().writeAll("export const FONT = Uint8Array.of(\n");
            for (font) |char| {
                try file.writer().writeAll("   ");
                for (char) |byte| {
                    try file.writer().print(" 0x{X:0>2},", .{byte});
                }
                try file.writer().writeByte('\n');
            }
            try file.writer().writeAll(");\n");
            file.close();
        }
    }.make;
}

pub const Cart = struct {
    mz: *MicroZig,
    fw: *MicroZig.Firmware,

    watch_run_cmd: *std.Build.Step.Run,
};

pub const CartOptions = struct {
    name: []const u8,
    optimize: std.builtin.OptimizeMode,
    root_source_file: Build.LazyPath,
};

pub fn add_cart(
    d: *Build.Dependency,
    b: *Build,
    options: CartOptions,
) *Cart {
    const wasm_lib = b.addExecutable(.{
        .name = "cart",
        .root_source_file = options.root_source_file,
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
        }),
        .optimize = options.optimize,
    });
    b.installArtifact(wasm_lib);

    wasm_lib.entry = .disabled;
    wasm_lib.import_memory = true;
    wasm_lib.initial_memory = 65536;
    wasm_lib.max_memory = 65536;
    wasm_lib.stack_size = 14752;
    wasm_lib.global_base = 160 * 128 * 2 + 0x1e;

    wasm_lib.rdynamic = true;

    wasm_lib.root_module.addImport("wasm4", d.module("wasm4"));

    const watch_wasm = d.builder.addExecutable(.{
        .name = "watch",
        .root_source_file = d.builder.path("src/watch/main.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = options.optimize,
    });
    watch_wasm.root_module.addImport("ws", d.builder.dependency("ws", .{}).module("websocket"));
    watch_wasm.root_module.addImport("mime", d.builder.dependency("mime", .{}).module("mime"));

    const watch_wasm_run_cmd = b.addRunArtifact(watch_wasm);
    watch_wasm_run_cmd.step.dependOn(b.getInstallStep());

    watch_wasm_run_cmd.addArgs(&.{
        "serve",
        b.graph.zig_exe,
        "--zig-out-bin-dir",
        b.pathJoin(&.{ b.install_path, "bin" }),
        "--input-dir",
        options.root_source_file.dirname().getPath(b),
    });

    const sycl_badge_2024 = getTarget(d);

    const cart_lib = b.addStaticLibrary(.{
        .name = "cart",
        .root_source_file = options.root_source_file,
        .target = b.resolveTargetQuery(sycl_badge_2024.chip.cpu.target),
        .optimize = options.optimize,
        .link_libc = false,
        .single_threaded = true,
        .use_llvm = true,
        .use_lld = true,
    });
    cart_lib.root_module.addImport("wasm4", d.module("wasm4"));

    const fw_options = b.addOptions();
    fw_options.addOption(bool, "have_cart", true);

    const mz = MicroZig.init(d.builder, .{});

    const fw = mz.add_firmware(d.builder, .{
        .name = options.name,
        .target = sycl_badge_2024,
        .optimize = .Debug, // TODO
        .root_source_file = d.builder.path("src/main.zig"),
        .linker_script = d.builder.path("src/cart.ld"),
    });
    fw.artifact.linkLibrary(cart_lib);
    fw.artifact.step.dependOn(&fw_options.step);
    fw.add_app_import("options", fw_options.createModule(), .{});

    const cart: *Cart = b.allocator.create(Cart) catch @panic("out of memory");
    cart.* = .{
        .mz = mz,
        .fw = fw,
        .watch_run_cmd = watch_wasm_run_cmd,
    };
    return cart;
}

pub fn install_cart(b: *Build, cart: *Cart) void {
    cart.mz.install_firmware(b, cart.fw, .{});
    cart.mz.install_firmware(b, cart.fw, .{ .format = .{ .uf2 = .SAMD51 } });
}
