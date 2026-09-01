// src/kernel/drivers/mouse.zig
//
// PS/2 Mouse Driver
// -----------------
// Initialises the PS/2 auxiliary port and puts the mouse into
// streaming mode so it generates IRQ12 on movement and button events.
//
// All communication goes through the 8042 PS/2 controller:
//   0x64 — command / status port
//   0x60 — data port
//
// No packet decoding is implemented here; that belongs in the IRQ12 handler.

const io = @import("../port_io.zig");
const fb = @import("../framebuffer.zig");
const vga = @import("../vga.zig");

// ----------------------------------------------------------------
// Private helpers
// ----------------------------------------------------------------

/// Busy-poll until the controller's input buffer is empty (bit 1 clear).
/// Must be called before writing to port 0x64 or 0x60.
fn waitWrite() void {
    while ((io.inb(0x64) & 0b10) != 0) {}
}

/// Busy-poll until the controller's output buffer is full (bit 0 set).
/// Must be called before reading from port 0x60.
fn waitRead() void {
    while ((io.inb(0x64) & 0b1) == 0) {}
}

/// Send a byte to the mouse via the PS/2 controller.
/// Prefixes the write with the 0xD4 "route to auxiliary device" command.
fn mouseWrite(byte: u8) void {
    waitWrite();
    io.outb(0x64, 0xD4);  // Route next data byte to the auxiliary (mouse) port
    waitWrite();
    io.outb(0x60, byte);
}

/// Read one byte from the PS/2 data port.
fn mouseRead() u8 {
    waitRead();
    return io.inb(0x60);
}

// ----------------------------------------------------------------
// Public interface
// ----------------------------------------------------------------

/// Initialise the PS/2 mouse.
///
/// Steps:
///   1. Enable the auxiliary PS/2 port
///   2. Enable IRQ12 in the controller configuration byte
///   3. Reset the mouse to its default state
///   4. Enable streaming mode (mouse sends packets on movement / click)
pub fn initMouse() void {
    // 1. Enable the auxiliary PS/2 port
    waitWrite();
    io.outb(0x64, 0xA8);

    // 2. Enable IRQ12 in the controller configuration byte
    waitWrite();
    io.outb(0x64, 0x20);  // Request current command byte
    waitRead();
    const status = io.inb(0x60);

    waitWrite();
    io.outb(0x64, 0x60);          // Write command byte
    waitWrite();
    io.outb(0x60, status | 0b10); // Set bit 1 to enable IRQ12

    // 3. Reset mouse to defaults
    mouseWrite(0xF6);
    _ = mouseRead();  // ACK

    // 4. Enable streaming mode
    mouseWrite(0xF4);
    _ = mouseRead();  // ACK
}


// Mouse position — clamped to screen bounds
pub var mouse_x: i32 = 400;  // start in centre
pub var mouse_y: i32 = 300;

// Dynamic resolution based on active mode
const SCREEN_W: i32 = if (vga.graphics_mode) 1024 else 800;
const SCREEN_H: i32 = if (vga.graphics_mode) 768 else 600;

// 16x16 baton cursor bitmap
// Each row is a u16, bit 15 = leftmost pixel, bit 0 = rightmost
// 1 = draw cursor pixel, 0 = transparent
const CURSOR_W = 16;
const CURSOR_H = 16;
// 16x16 Single Semi Quaver (Eighth Note) Cursor
// Bit 15 = leftmost pixel, Bit 0 = rightmost pixel
// 16x16 Beamed Musical Notes Cursor
// Hotspot is at top-left (col 15 of row 0)
const cursor_bitmap: [CURSOR_H]u16 = .{
    0b0011111001100000, // row 0  — Beam Top (Connected to Stem, arching left)
    0b0000111101100000, // row 1  — Beam arching down-left
    0b0000001111100000, // row 2  — Beam end (Gap start)
    0b0000000001100000, // row 3  — Stem only (Gap)
    0b0011111001100000, // row 4  — Beam Top (Connected to Stem, arching left)
    0b0000111101100000, // row 5  — Beam arching down-left
    0b0000001111100000, // row 6  — Beam end
    0b0000000001100000, // row 7  — Stem only
    0b0000000001100000, // row 8  — Stem only
    0b0000000001100000, // row 9  — Stem only
    0b0000000001100000, // row 10 — Stem only
    0b0000000001100000, // row 11 — Stem only
    0b0000000001100000, // row 12 — Stem meets Notehead
    0b0000000001101111, // row 13 — Notehead Top
    0b0000000001111111, // row 14 — Notehead Full
    0b0000000000111110, // row 15 — Notehead Bottom
};

// Saved pixels under cursor (24bpp = 3 bytes per pixel)
var save_buffer: [CURSOR_W * CURSOR_H * 3]u8 = undefined;
var cursor_saved: bool = false;
var saved_x: i32 = 0;
var saved_y: i32 = 0;

/// Update mouse position from a decoded packet delta.
/// Clamps to screen bounds.
pub fn updatePosition(dx: i8, dy: i8) void {
    mouse_x += @as(i32, dx);
    mouse_y -= @as(i32, dy); // PS/2 dy is inverted

    // Read real framebuffer dimensions dynamically instead of hardcoded numbers
    const max_w = @as(i32, @intCast(fb.fb_width));
    const max_h = @as(i32, @intCast(fb.fb_height));

    if (mouse_x < 0) mouse_x = 0;
    if (mouse_y < 0) mouse_y = 0;

    if (mouse_x >= max_w - CURSOR_W) mouse_x = max_w - CURSOR_W;
    if (mouse_y >= max_h - CURSOR_H) mouse_y = max_h - CURSOR_H;
}

/// Save the pixels currently under the cursor position.
fn saveCursor(x: i32, y: i32) void {
    const fb_ptr = @as([*]volatile u8, @ptrFromInt(@as(usize, 0x3E000000)));
    const stride = fb.fb_stride;

    var row: i32 = 0;
    while (row < CURSOR_H) : (row += 1) {
        var col: i32 = 0;
        while (col < CURSOR_W) : (col += 1) {
            const px = x + col;
            const py = y + row;

            const fb_offset = @as(usize, @intCast(py)) * stride + @as(usize, @intCast(px)) * 3;
            const buf_offset = @as(usize, @intCast(row * CURSOR_W + col)) * 3;

            save_buffer[buf_offset + 0] = fb_ptr[fb_offset + 0];
            save_buffer[buf_offset + 1] = fb_ptr[fb_offset + 1];
            save_buffer[buf_offset + 2] = fb_ptr[fb_offset + 2];
        }
    }
    cursor_saved = true;
    saved_x = x;
    saved_y = y;
}

pub fn eraseCursor() void {
    if (!cursor_saved) return;
    const fb_ptr = @as([*]volatile u8, @ptrFromInt(@as(usize, 0x3E000000)));
    const stride = fb.fb_stride;

    var row: i32 = 0;
    while (row < CURSOR_H) : (row += 1) {
        var col: i32 = 0;
        while (col < CURSOR_W) : (col += 1) {
            const px = saved_x + col;
            const py = saved_y + row;

            const fb_offset = @as(usize, @intCast(py)) * stride + @as(usize, @intCast(px)) * 3;
            const buf_offset = @as(usize, @intCast(row * CURSOR_W + col)) * 3;

            fb_ptr[fb_offset + 0] = save_buffer[buf_offset + 0];
            fb_ptr[fb_offset + 1] = save_buffer[buf_offset + 1];
            fb_ptr[fb_offset + 2] = save_buffer[buf_offset + 2];
        }
    }
    cursor_saved = false;
}

/// Draw the baton cursor at position (x, y).
pub fn drawCursor(x: i32, y: i32) void {
    if (!vga.graphics_mode) return; // only in VESA mode
    saveCursor(x, y);
    const fb_ptr = @as([*]volatile u8, @ptrFromInt(@as(usize, 0x3E000000)));
    const stride = fb.fb_stride;
    const max_w = if (vga.graphics_mode) @as(i32, 1024) else 800;
    const max_h = if (vga.graphics_mode) @as(i32, 768) else 600;
    var row: i32 = 0;
    while (row < CURSOR_H) : (row += 1) {
        const bitmap_row = cursor_bitmap[@as(usize, @intCast(row))];
        var col: i32 = 0;
        while (col < CURSOR_W) : (col += 1) {
            const bit = @as(u16, 1) << @truncate(@as(u5, @intCast(15 - col)));
            if ((bitmap_row & bit) == 0) continue; // transparent
            const px = x + col;
            const py = y + row;
            if (px < 0 or py < 0 or px >= max_w or py >= max_h) continue;
            const fb_offset = @as(usize, @intCast(py)) * stride +
            @as(usize, @intCast(px)) * 3;
            // White baton — BGR format
            fb_ptr[fb_offset + 0] = 0xFF; // B
            fb_ptr[fb_offset + 1] = 0xFF; // G
            fb_ptr[fb_offset + 2] = 0xFF; // R
        }
    }
}
