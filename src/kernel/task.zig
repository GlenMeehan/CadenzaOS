// src/kernel/task.zig
//
// Demonstration and scheduler-test tasks.
//
// These tasks provide visible activity that can be used to verify
// task creation, scheduling, timing, preemption, and display output
// across both VGA text mode and framebuffer graphics mode.
//
const std = @import("std");
const config = @import("config.zig");
const scheduler = @import("scheduler.zig");
const vga_mod = @import("vga.zig");
const fb = @import("framebuffer.zig");
const font = @import("font.zig");

/// Demonstration task A.
///
/// Displays a continuously increasing execution counter and flashes
/// an 'A' indicator to make task activity visible while testing the
/// scheduler.
pub fn taskA_main() callconv(.c) void {
    asm volatile ("sti");

    const vga_ptr = @as([*]volatile u16, @ptrFromInt(0xB8000));
    var run_count: u32 = 0;

    while (true) {
        run_count += 1;

        draw_counter(
            vga_ptr,
            1900,
            run_count,
            23,
            60,
        ); // Row 23, Column 60

        // Flash an activity indicator approximately once every
        // half second.
        draw_char(vga_ptr, 1919, 23, 79, 'A', 0x0A);

        sleep(500);

        draw_char(vga_ptr, 1919, 23, 79, ' ', 0x07);

        sleep(500);

    }
}

/// Demonstration task B.
///
/// Displays a separate execution counter and flashes a 'B'
/// indicator to provide a second independently scheduled workload.
pub fn taskB_main() callconv(.c) void {
    asm volatile ("sti");

    const vga_ptr = @as([*]volatile u16, @ptrFromInt(0xB8000));
    var run_count: u32 = 0;

    while (true) {
        run_count += 1;

        draw_counter(
            vga_ptr,
            1980,
            run_count,
            24,
            60,
        ); // Row 24, Column 60

        // Flash an activity indicator at a higher frequency than
        // taskA_main() to make scheduling behaviour easier to observe.
        draw_char(vga_ptr, 1999, 24, 79, 'B', 0x09);

        sleep(250);

        draw_char(vga_ptr, 1999, 24, 79, ' ', 0x07);

        sleep(250);
    }
}

/// Render a four-digit hexadecimal counter value.
///
/// Output is automatically routed to either the framebuffer renderer
/// or the VGA text buffer depending on the active video mode.
fn draw_counter(
    vga: [*]volatile u16,
    vga_pos: usize,
    val: u32,
    row: usize,
    col: usize,
) void {
    const hex = "0123456789ABCDEF";

    var buf: [4]u8 = undefined;
    var v = val;

    var i: usize = 0;
    while (i < 4) : (i += 1) {
        buf[3 - i] = hex[v & 0xF];
        v >>= 4;
    }

    if (vga_mod.graphics_mode) {

        // Draw directly at pixel coordinates without modifying
        // the shared text-console cursor state.
        const x: u32 = @intCast(col * font.GLYPH_WIDTH);
        const y: u32 = @intCast(row * font.GLYPH_HEIGHT);

        fb.drawStringAtPixel(
            x,
            y,
            &buf,
            fb.paletteColor(0x0E),
                             fb.paletteColor(0),
        );
    } else {

        // Direct VGA text-mode rendering.
        for (buf, 0..) |char, b_idx| {
            vga[vga_pos + b_idx] =
            (@as(u16, 0x0E) << 8) | char;
        }
    }
}

/// Render a single character using either framebuffer graphics mode
/// or direct VGA text-mode output.
fn draw_char(
    vga: [*]volatile u16,
    vga_pos: usize,
    row: usize,
    col: usize,
    char: u8,
    color: u8,
) void {
    if (vga_mod.graphics_mode) {
        const buf = [1]u8{char};

        const x: u32 = @intCast(col * font.GLYPH_WIDTH);
        const y: u32 = @intCast(row * font.GLYPH_HEIGHT);

        fb.drawStringAtPixel(
            x,
            y,
            &buf,
            fb.paletteColor(color & 0x0F),
                             fb.paletteColor((color >> 4) & 0x0F),
        );
    } else {
        vga[vga_pos] = (@as(u16, color) << 8) | char;
    }
}

/// Crude busy-wait delay.
///
/// Primarily intended for scheduler demonstrations and simple timing
/// tests. The actual delay duration depends on processor speed and
/// should not be considered precise.
pub fn sleep(ms: u64) void {
    var i: u64 = 0;

    const target = ms * 10000;

    while (i < target) : (i += 1) {
        asm volatile ("nop");
    }
}
