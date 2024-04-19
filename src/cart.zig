const w4 = @import("wasm4.zig");
const font = @import("font.zig").font;

pub fn init() void {
    @setCold(true);

    for (Port.BUTTON) |button| {
        button.set_dir(.in);
        button.set_dir(.in);
        button.config_ptr().write(.{
            .PMUXEN = 0,
            .INEN = 1,
            .PULLEN = 0,
            .reserved6 = 0,
            .DRVSTR = 0,
            .padding = 0,
        });
    }

    timer.init_frame_sync();

    @memset(@as(*[0x19A0]u8, @ptrFromInt(0x20000000)), 0);

    if (!options.have_cart) return;

    // fill .bss with zeroes
    {
        const bss_start: [*]u8 = @ptrCast(&libcart.cart_bss_start);
        const bss_end: [*]u8 = @ptrCast(&libcart.cart_bss_end);
        const bss_len = @intFromPtr(bss_end) - @intFromPtr(bss_start);

        @memset(bss_start[0..bss_len], 0);
    }

    // load .data from flash
    {
        const data_start: [*]u8 = @ptrCast(&libcart.cart_data_start);
        const data_end: [*]u8 = @ptrCast(&libcart.cart_data_end);
        const data_len = @intFromPtr(data_end) - @intFromPtr(data_start);
        const data_src: [*]const u8 = @ptrCast(&libcart.cart_data_load_start);

        @memcpy(data_start[0..data_len], data_src[0..data_len]);
    }
}

pub fn start() void {
    call(if (options.have_cart) &libcart.start else &struct {
        fn start() callconv(.C) void {
            w4.trace("start");
        }
    }.start);
}

pub fn tick() void {
    if (!timer.check_frame_ready()) return;

    @constCast(w4.controls).* = .{
        .select = switch (Port.BUTTON[0].read()) {
            .low => true,
            .high => false,
        },
        .start = switch (Port.BUTTON[1].read()) {
            .low => true,
            .high => false,
        },
        .a = switch (Port.BUTTON[2].read()) {
            .low => true,
            .high => false,
        },
        .b = switch (Port.BUTTON[3].read()) {
            .low => true,
            .high => false,
        },
        .left = switch (Port.BUTTON[8].read()) {
            .low => true,
            .high => false,
        },
        .right = switch (Port.BUTTON[7].read()) {
            .low => true,
            .high => false,
        },
        .up = switch (Port.BUTTON[4].read()) {
            .low => true,
            .high => false,
        },
        .down = switch (Port.BUTTON[5].read()) {
            .low => true,
            .high => false,
        },
        .click = switch (Port.BUTTON[6].read()) {
            .low => true,
            .high => false,
        },
    };
    call(if (options.have_cart) &libcart.update else &struct {
        fn update() callconv(.C) void {
            const global = struct {
                var tick: u8 = 0;
                var stroke: bool = true;
                var radius: u32 = 0;
                var note: usize = 0;
            };
            w4.oval(
                .{ .red = 0x1f, .green = 0, .blue = 0 },
                if (global.stroke) .{ .red = 0x1f, .green = 0x3f, .blue = 0x1f } else null,
                @as(i32, lcd.width / 2) -| @min(global.radius, std.math.maxInt(i32)),
                @as(i32, lcd.height / 2) -| @min(global.radius, std.math.maxInt(i32)),
                global.radius * 2,
                global.radius * 2,
            );
            const controls = w4.controls.*;
            inline for (@typeInfo(w4.Controls).Struct.fields, 0..) |field, button|
                if (@field(controls, field.name)) w4.text(
                    .{ .red = 0x1f, .green = 0x3f, .blue = 0x1f },
                    null,
                    &.{0x80 + @as(u8, @intCast(button))},
                    20 + @as(u8, @intCast(button)) * 16,
                    60,
                );
            global.tick += 1;
            if (global.tick == 10) {
                global.tick = 0;
                global.stroke = !global.stroke;
                if (global.stroke) {
                    global.radius += 1;
                    if (global.radius == 100) {
                        global.radius = 0;
                    }
                }

                w4.tone(([_]u16{
                    880, 831, 784, 740, 698, 659, 622, 587, 554, 523, 494, 466,
                    440, 415, 392, 370, 349, 330, 311, 294, 277, 262, 247, 233,
                    220, 207, 196, 185, 175, 165, 156, 147, 139, 131, 123, 117,
                    110,
                })[global.note], 10, 50, .{
                    .channel = .pulse1,
                    .duty_cycle = .@"1/8",
                    .panning = .stereo,
                });
                global.note += 1;
                if (global.note == 37) global.note = 0;
            }
        }
    }.update);
}

pub fn blit(colors: [*]const User(w4.OptionalDisplayColor), sprite: [*]const User(u8), x: i32, rest: *const extern struct { y: User(i32), width: User(u32), height: User(u32), flags: User(w4.BlitFlags) }) callconv(.C) void {
    const y = rest.y.load();
    const width = rest.width.load();
    const height = rest.height.load();
    const flags = rest.flags.load();

    if (flags.flip_x or flags.flip_y or flags.rotate) return;
    switch (flags.bits_per_pixel) {
        .one => for (0..height) |sprite_y| {
            for (0..width) |sprite_x| {
                const sprite_index = sprite_x + width * sprite_y;
                const draw_color_index: u1 = @truncate(sprite[sprite_index >> 3].load() >>
                    (7 - @as(u3, @truncate(sprite_index))));
                clip_draw(
                    x +| @min(sprite_x, std.math.maxInt(i32)),
                    y +| @min(sprite_y, std.math.maxInt(i32)),
                    colors[draw_color_index].load().unwrap(),
                );
            }
        },
        .two => for (0..height) |sprite_y| {
            for (0..width) |sprite_x| {
                const sprite_index = sprite_x + width * sprite_y;
                const draw_color_index: u2 = @truncate(sprite[sprite_index >> 2].load() >>
                    (6 - (@as(u3, @as(u2, @truncate(sprite_index))) << 1)));
                clip_draw(
                    x +| @min(sprite_x, std.math.maxInt(i32)),
                    y +| @min(sprite_y, std.math.maxInt(i32)),
                    colors[draw_color_index].load().unwrap(),
                );
            }
        },
    }
}

pub fn blit_sub(colors: [*]const User(w4.OptionalDisplayColor), sprite: [*]const User(u8), x: i32, rest: *const extern struct { y: User(i32), width: User(u32), height: User(u32), src_x: User(u32), src_y: User(u32), stride: User(u32), flags: User(w4.BlitFlags) }) callconv(.C) void {
    const y = rest.y.load();
    const src_x = rest.src_x.load();
    const src_y = rest.src_y.load();
    const stride = rest.stride.load();
    const width = rest.width.load();
    const height = rest.height.load();
    const flags = rest.flags.load();

    if (flags.flip_x or flags.flip_y or flags.rotate) return;
    switch (flags.bits_per_pixel) {
        .one => for (0..height) |sprite_y| {
            for (0..width) |sprite_x| {
                const sprite_index = (src_x + sprite_x) + stride * (src_y + sprite_y);
                const draw_color_index: u1 = @truncate(sprite[sprite_index >> 3].load() >>
                    (7 - @as(u3, @truncate(sprite_index))));
                clip_draw(
                    x +| @min(sprite_x, std.math.maxInt(i32)),
                    y +| @min(sprite_y, std.math.maxInt(i32)),
                    colors[draw_color_index].load().unwrap(),
                );
            }
        },
        .two => for (0..height) |sprite_y| {
            for (0..width) |sprite_x| {
                const sprite_index = (src_x + sprite_x) + stride * (src_y + sprite_y);
                const draw_color_index: u2 = @truncate(sprite[sprite_index >> 2].load() >>
                    (6 - (@as(u3, @as(u2, @truncate(sprite_index))) << 1)));
                clip_draw(
                    x +| @min(sprite_x, std.math.maxInt(i32)),
                    y +| @min(sprite_y, std.math.maxInt(i32)),
                    colors[draw_color_index].load().unwrap(),
                );
            }
        },
    }
}

pub fn line(color: w4.DisplayColor, x1: i32, y1: i32, rest: *const extern struct { x2: User(i32), y2: User(i32) }) void {
    const x2 = rest.x2.load();
    const y2 = rest.y2.load();

    _ = color;
    _ = x1;
    _ = y1;
    _ = x2;
    _ = y2;
}

pub fn oval(stroke_color: w4.OptionalDisplayColor, fill_color: w4.OptionalDisplayColor, x: i32, rest: *const extern struct { y: User(i32), width: User(u32), height: User(u32) }) callconv(.C) void {
    const y = rest.y.load();
    const width = rest.width.load();
    const height = rest.height.load();

    if (stroke_color == .none and fill_color == .none) return;
    if (width == 0 or height == 0 or x >= w4.screen_width or y >= w4.screen_height) return;
    const end_x = x +| @min(width, std.math.maxInt(i32));
    const end_y = y +| @min(height, std.math.maxInt(i32));
    if (end_x < 0 or end_y < 0) return;

    switch (std.math.order(width, height)) {
        .lt => rect(stroke_color, fill_color, x, &.{ .y = .{ .unsafe = y }, .width = .{ .unsafe = width }, .height = .{ .unsafe = height } }),
        .eq => {
            const size: u31 = @intCast(width >> 1);
            const mid_x = x +| size;
            const mid_y = y +| size;

            var cur_x: u31 = 0;
            var cur_y: u31 = size;
            var err: i32 = size >> 1;
            while (cur_x <= cur_y) {
                if (fill_color.unwrap()) |c| {
                    hline(c, mid_x -| cur_y, mid_y -| cur_x, cur_y << 1);
                    hline(c, mid_x -| cur_y, mid_y +| cur_x, cur_y << 1);
                }
                if (stroke_color != .none) {
                    clip_draw(mid_x -| cur_x, mid_y -| cur_y, stroke_color.unwrap());
                    clip_draw(mid_x +| cur_x, mid_y -| cur_y, stroke_color.unwrap());
                    clip_draw(mid_x -| cur_y, mid_y -| cur_x, stroke_color.unwrap());
                    clip_draw(mid_x +| cur_y, mid_y -| cur_x, stroke_color.unwrap());
                    clip_draw(mid_x -| cur_y, mid_y +| cur_x, stroke_color.unwrap());
                    clip_draw(mid_x +| cur_y, mid_y +| cur_x, stroke_color.unwrap());
                    clip_draw(mid_x -| cur_x, mid_y +| cur_y, stroke_color.unwrap());
                    clip_draw(mid_x +| cur_x, mid_y +| cur_y, stroke_color.unwrap());
                }
                cur_x += 1;
                err += cur_x;
                const temp = err - cur_y;
                if (temp >= 0) {
                    err = temp;
                    cur_y -= 1;

                    if (cur_x <= cur_y) {
                        if (fill_color.unwrap()) |c| {
                            hline(c, mid_x -| cur_x, mid_y -| cur_y, cur_x << 1);
                            hline(c, mid_x -| cur_x, mid_y +| cur_y, cur_x << 1);
                        }
                    }
                }
            }
        },
        .gt => rect(stroke_color, fill_color, x, &.{ .y = .{ .unsafe = y }, .width = .{ .unsafe = width }, .height = .{ .unsafe = height } }),
    }
}

pub fn rect(stroke_color: w4.OptionalDisplayColor, fill_color: w4.OptionalDisplayColor, x: i32, rest: *const extern struct { y: User(i32), width: User(u32), height: User(u32) }) callconv(.C) void {
    const y = rest.y.load();
    const width = rest.width.load();
    const height = rest.height.load();

    if (stroke_color == .none and fill_color == .none) return;
    if (width == 0 or height == 0 or x >= w4.screen_width or y >= w4.screen_height) return;
    const end_x = x +| @min(width, std.math.maxInt(i32));
    const end_y = y +| @min(height, std.math.maxInt(i32));
    if (end_x < 0 or end_y < 0) return;

    if (stroke_color != .none) {
        if (y >= 0 and y < w4.screen_height) {
            for (@max(x, 0)..@intCast(@min(end_x, w4.screen_width))) |cur_x| {
                draw(@intCast(cur_x), @intCast(y), stroke_color.unwrap());
            }
        }
    }
    if (height > 2) {
        for (@max(y + 1, 0)..@intCast(@min(end_y - 1, w4.screen_height))) |cur_y| {
            if (x >= 0 and x < w4.screen_width) {
                draw(@intCast(x), @intCast(cur_y), stroke_color.unwrap());
            }
            if (fill_color != .none) {
                if (width > 2) {
                    for (@max(x + 1, 0)..@intCast(@min(end_x - 1, w4.screen_width))) |cur_x| {
                        draw(@intCast(cur_x), @intCast(cur_y), fill_color.unwrap());
                    }
                }
            }
            if (width > 1 and end_x - 1 >= 0 and end_x - 1 < w4.screen_width) {
                draw(@intCast(end_x - 1), @intCast(cur_y), stroke_color.unwrap());
            }
        }
    }
    if (stroke_color != .none) {
        if (height > 1 and end_y - 1 >= 0 and end_y - 1 < w4.screen_height) {
            for (@max(x, 0)..@intCast(@min(end_x, w4.screen_width))) |cur_x| {
                draw(@intCast(cur_x), @intCast(end_y - 1), stroke_color.unwrap());
            }
        }
    }
}

pub fn text(text_color: w4.DisplayColor, background_color: w4.OptionalDisplayColor, str_ptr: [*]const User(u8), rest: *const extern struct { str_len: User(usize), x: User(i32), y: User(i32) }) callconv(.C) void {
    const str = str_ptr[0..rest.str_len.load()];
    const x = rest.x.load();
    const y = rest.y.load();

    var cur_x = x;
    var cur_y = y;
    for (str) |*byte| switch (byte.load()) {
        else => cur_x +|= 8,
        '\n' => {
            cur_x = x;
            cur_y +|= 8;
        },
        ' '...0xFF => |char| {
            const glyph = &font[char - ' '];
            blit_unsafe(&.{ text_color, background_color.unwrap() }, glyph, cur_x, cur_y, 8, 8, .{ .bits_per_pixel = .one });
            cur_x +|= 8;
        },
    };
}

pub fn vline(color: w4.DisplayColor, x: i32, y: i32, len: u32) callconv(.C) void {
    if (len == 0 or x < 0 or x >= w4.screen_width or y >= w4.screen_height) return;
    const end_y = y +| @min(len, std.math.maxInt(i32));
    if (end_y < 0) return;

    for (@max(y, 0)..@intCast(@min(end_y, w4.screen_height))) |cur_y| {
        draw(@intCast(x), @intCast(cur_y), color);
    }
}

pub fn hline(color: w4.DisplayColor, x: i32, y: i32, len: u32) callconv(.C) void {
    if (len == 0 or y < 0 or y >= w4.screen_width or x >= w4.screen_height) return;
    const end_x = x +| @min(len, std.math.maxInt(i32));
    if (end_x < 0) return;

    for (@max(x, 0)..@intCast(@min(end_x, w4.screen_width))) |cur_x| {
        draw(@intCast(cur_x), @intCast(y), color);
    }
}

pub fn tone(frequency: u32, duration: u32, volume: u32, flags: w4.ToneFlags) callconv(.C) void {
    const start_frequency: u16 = @truncate(frequency >> 0);
    const end_frequency = switch (@as(u16, @truncate(frequency >> 16))) {
        0 => start_frequency,
        else => |end_frequency| end_frequency,
    };
    const sustain_time: u8 = @truncate(duration >> 0);
    const release_time: u8 = @truncate(duration >> 8);
    const decay_time: u8 = @truncate(duration >> 16);
    const attack_time: u8 = @truncate(duration >> 24);
    const total_time = @as(u10, attack_time) + decay_time + sustain_time + release_time;
    const sustain_volume: u8 = @truncate(volume >> 0);
    const peak_volume = switch (@as(u8, @truncate(volume >> 8))) {
        0 => 100,
        else => |attack_volume| attack_volume,
    };

    var state: audio.Channel = .{
        .duty = 0,
        .phase = 0,
        .phase_step = 0,
        .phase_step_step = 0,

        .duration = 0,
        .attack_duration = 0,
        .decay_duration = 0,
        .sustain_duration = 0,
        .release_duration = 0,

        .volume = 0,
        .volume_step = 0,
        .peak_volume = 0,
        .sustain_volume = 0,
        .attack_volume_step = 0,
        .decay_volume_step = 0,
        .release_volume_step = 0,
    };

    const start_phase_step = @mulWithOverflow((1 << 32) / 44100, @as(u31, start_frequency));
    const end_phase_step = @mulWithOverflow((1 << 32) / 44100, @as(u31, end_frequency));
    if (start_phase_step[1] != 0 or end_phase_step[1] != 0) return;
    state.phase_step = start_phase_step[0];
    state.phase_step_step = @divTrunc(@as(i32, end_phase_step[0]) - start_phase_step[0], @as(u20, total_time) * @divExact(44100, 60));

    state.attack_duration = @as(u18, attack_time) * @divExact(44100, 60);
    state.decay_duration = @as(u18, decay_time) * @divExact(44100, 60);
    state.sustain_duration = @as(u18, sustain_time) * @divExact(44100, 60);
    state.release_duration = @as(u18, release_time) * @divExact(44100, 60);

    state.peak_volume = @as(u29, peak_volume) << 21;
    state.sustain_volume = @as(u29, sustain_volume) << 21;
    if (state.attack_duration > 0) {
        state.attack_volume_step = @divTrunc(@as(i32, state.peak_volume) - 0, state.attack_duration);
    }
    if (state.decay_duration > 0) {
        state.decay_volume_step = @divTrunc(@as(i32, state.sustain_volume) - state.peak_volume, state.decay_duration);
    }
    if (state.release_duration > 0) {
        state.release_volume_step = @divTrunc(@as(i32, 0) - state.sustain_volume, state.release_duration);
    }

    switch (flags.channel) {
        .pulse1, .pulse2 => {
            state.duty = switch (flags.duty_cycle) {
                .@"1/8" => (1 << 32) / 8,
                .@"1/4" => (1 << 32) / 4,
                .@"1/2" => (1 << 32) / 2,
                .@"3/4" => (3 << 32) / 4,
            };
        },
        .triangle => {
            state.duty = (1 << 32) / 2;
        },
        .noise => {
            state.duty = (1 << 32) / 2;
        },
    }

    audio.set_channel(@intFromEnum(flags.channel), state);
}

pub fn read_flash(offset: u32, dst_ptr: [*]User(u8), dst_len: usize) callconv(.C) void {
    const dst = dst_ptr[0..dst_len];

    _ = offset;
    _ = dst;
}

pub fn write_flash_page(page: u16, src: *const [w4.flash_page_size]User(u8)) void {
    _ = page;
    _ = src;
}

pub fn trace(str: [*]const User(u8), len: usize) callconv(.C) void {
    std.log.scoped(.trace).info("{}", .{fmt_user_string(str[0..len])});
}

fn call(func: *const fn () callconv(.C) void) void {
    const process_stack = utils.HSRAM.ADDR[utils.HSRAM.SIZE - @divExact(
        utils.HSRAM.SIZE,
        3 * 2,
    ) ..][0..@divExact(utils.HSRAM.SIZE, 3 * 4)];
    const frame = comptime std.mem.bytesAsSlice(u32, process_stack[process_stack.len - 0x20 ..]);
    @memset(frame[0..5], 0);
    frame[5] = @intFromPtr(&libcart.__return_thunk__);
    frame[6] = @intFromPtr(func);
    frame[7] = 1 << 24;
    asm volatile (
        \\ msr psp, %[process_stack]
        \\ svc #12
        :
        : [process_stack] "r" (frame.ptr),
        : "memory"
    );
}

fn blit_unsafe(colors: []const ?w4.DisplayColor, sprite: [*]const u8, x: i32, y: i32, width: u32, height: u32, flags: w4.BlitFlags) void {
    if (flags.flip_x or flags.flip_y or flags.rotate) return;
    switch (flags.bits_per_pixel) {
        .one => for (0..height) |sprite_y| {
            for (0..width) |sprite_x| {
                const sprite_index = sprite_x + width * sprite_y;
                const draw_color_index: u1 = @truncate(sprite[sprite_index >> 3] >>
                    (7 - @as(u3, @truncate(sprite_index))));
                clip_draw(
                    x +| @min(sprite_x, std.math.maxInt(i32)),
                    y +| @min(sprite_y, std.math.maxInt(i32)),
                    colors[draw_color_index],
                );
            }
        },
        .two => for (0..height) |sprite_y| {
            for (0..width) |sprite_x| {
                const sprite_index = sprite_x + width * sprite_y;
                const draw_color_index: u2 = @truncate(sprite[sprite_index >> 2] >>
                    (6 - (@as(u3, @as(u2, @truncate(sprite_index))) << 1)));
                clip_draw(
                    x +| @min(sprite_x, std.math.maxInt(i32)),
                    y +| @min(sprite_y, std.math.maxInt(i32)),
                    colors[draw_color_index],
                );
            }
        },
    }
}

inline fn clip_draw(x: i32, y: i32, color: ?w4.DisplayColor) void {
    if (x < 0 or x >= w4.screen_width or y < 0 or y >= w4.screen_height) return;
    draw(@intCast(x), @intCast(y), color);
}

inline fn draw(x: u8, y: u8, color: ?w4.DisplayColor) void {
    std.debug.assert(x < w4.screen_width and y < w4.screen_height);
    w4.framebuffer[x + w4.screen_width * y] = color orelse return;
}

fn format_user_string(bytes: []const User(u8), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) @TypeOf(writer).Error!void {
    for (bytes) |*byte| try writer.writeByte(byte.load());
}
inline fn fmt_user_string(bytes: []const User(u8)) std.fmt.Formatter(format_user_string) {
    return .{ .data = bytes };
}

fn User(comptime T: type) type {
    return extern struct {
        const Self = @This();
        const suffix = switch (@sizeOf(T)) {
            1 => "b",
            2 => "h",
            4 => "",
            else => @compileError("loadUser doesn't support " ++ @typeName(T)),
        };

        unsafe: T,

        pub inline fn load(user: *const Self) T {
            return asm ("ldr" ++ suffix ++ "t %[value], [%[pointer]]"
                : [value] "=r" (-> T),
                : [pointer] "r" (&user.unsafe),
            );
        }

        pub inline fn store(user: *Self, value: T) void {
            asm volatile ("str" ++ suffix ++ "t %[value], [%pointer]]"
                :
                : [value] "r" (value),
                  [pointer] "r" (&user.unsafe),
            );
        }
    };
}

const libcart = struct {
    extern var cart_data_start: u8;
    extern var cart_data_end: u8;
    extern var cart_bss_start: u8;
    extern var cart_bss_end: u8;
    extern const cart_data_load_start: u8;

    extern fn start() void;
    extern fn update() void;
    extern fn __return_thunk__() noreturn;
};

const audio = @import("audio.zig");
const lcd = @import("lcd.zig");
const options = @import("options");
const Port = @import("Port.zig");
const std = @import("std");
const timer = @import("timer.zig");
const utils = @import("utils.zig");
