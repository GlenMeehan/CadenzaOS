// src/kernel/task.zig

const std = @import("std");
const config = @import("config.zig");
const scheduler = @import("scheduler.zig");
// 1. Import your VGA module so we can check mode and call writeString
const vga_mod = @import("vga.zig");
const fb = @import("framebuffer.zig");
const font = @import("font.zig");

pub fn taskA_main() callconv(.c) void {
    asm volatile ("sti");
    const vga_ptr = @as([*]volatile u16, @ptrFromInt(0xB8000));
    var run_count: u32 = 0;

    while (true) {
        run_count += 1;
        draw_counter(vga_ptr, 1900, run_count, 23, 60); // Row 23, Col 60

        // Flash 'A' once every half second
        draw_char(vga_ptr, 1919, 23, 79, 'A', 0x0A);
        sleep(500);

        draw_char(vga_ptr, 1919, 23, 79, ' ', 0x07);
        sleep(500);

        scheduler.manager.yield();
    }
}

pub fn taskB_main() callconv(.c) void {
    asm volatile ("sti");
    const vga_ptr = @as([*]volatile u16, @ptrFromInt(0xB8000));
    var run_count: u32 = 0;

    while (true) {
        run_count += 1;
        draw_counter(vga_ptr, 1980, run_count, 24, 60); // Row 24, Col 60

        // Flash 'B' 4 times a second (250ms on, 250ms off)
        draw_char(vga_ptr, 1999, 24, 79, 'B', 0x09);
        sleep(250);

        draw_char(vga_ptr, 1999, 24, 79, ' ', 0x07);
        sleep(250);
    }
}

/// Unified counter renderer that automatically routes to VESA or direct VGA
fn draw_counter(vga: [*]volatile u16, vga_pos: usize, val: u32, row: usize, col: usize) void {
    const hex = "0123456789ABCDEF";
    var buf: [4]u8 = undefined;
    var v = val;

    var i: usize = 0;
    while (i < 4) : (i += 1) {
        buf[3 - i] = hex[v & 0xF];
        v >>= 4;
    }

    if (vga_mod.graphics_mode) {
        // Draw straight to pixel coordinates: no shared cursor state touched.
        const x: u32 = @intCast(col * font.GLYPH_WIDTH);
        const y: u32 = @intCast(row * font.GLYPH_HEIGHT);
        fb.drawStringAtPixel(x, y, &buf, fb.paletteColor(0x0E), fb.paletteColor(0));
    } else {
        for (buf, 0..) |char, b_idx| {
            vga[vga_pos + b_idx] = (@as(u16, 0x0E) << 8) | char;
        }
    }
}

fn draw_char(vga: [*]volatile u16, vga_pos: usize, row: usize, col: usize, char: u8, color: u8) void {
    if (vga_mod.graphics_mode) {
        const buf = [1]u8{char};
        const x: u32 = @intCast(col * font.GLYPH_WIDTH);
        const y: u32 = @intCast(row * font.GLYPH_HEIGHT);
        fb.drawStringAtPixel(x, y, &buf, fb.paletteColor(color & 0x0F), fb.paletteColor((color >> 4) & 0x0F));
    } else {
        vga[vga_pos] = (@as(u16, color) << 8) | char;
    }
}

/// Puts the currently executing task to sleep for a specified number of milliseconds.
pub fn sleep(ms: u64) void {
    var i: u64 = 0;
    const target = ms * 10000;
    while (i < target) : (i += 1) {
        asm volatile ("nop");
    }
}
