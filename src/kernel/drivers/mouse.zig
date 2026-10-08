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
/// Must be called before writing commands/data to port 0x64 or 0x60.
fn waitWrite() void {
    while ((io.inb(0x64) & 0b10) != 0) {}
}

/// Busy-poll until the controller's output buffer is full (bit 0 set).
/// Must be called before reading byte data from port 0x60.
fn waitRead() void {
    while ((io.inb(0x64) & 0b1) == 0) {}
}

/// Send a byte command or data directly to the secondary PS/2 device (mouse).
/// Prefixes the write with the 0xD4 command on port 0x64, which instructs the
/// 8042 controller to route the subsequent data byte on port 0x60 to the mouse.
fn mouseWrite(byte: u8) void {
    waitWrite();
    io.outb(0x64, 0xD4); // Route next data byte to the auxiliary (mouse) port
    waitWrite();
    io.outb(0x60, byte);
}

/// Read one byte directly from the PS/2 data port (0x60) after waiting for data ready.
fn mouseRead() u8 {
    waitRead();
    return io.inb(0x60);
}

// ----------------------------------------------------------------
// Public interface
// ----------------------------------------------------------------

/// Initialise the PS/2 mouse into streaming mode.
///
/// Hardware Initialization Steps:
///   1. Send command 0xA8 to port 0x64 to enable the auxiliary PS/2 port.
///   2. Read the 8042 controller configuration byte (Command 0x20), set Bit 1
///      to enable IRQ12 generation, and write it back (Command 0x60).
///   3. Write command 0xF6 to reset mouse settings to default parameters.
///   4. Write command 0xF4 to start packet streaming mode on movement and click events.
pub fn initMouse() void {
    // 1. Enable the auxiliary PS/2 port
    waitWrite();
    io.outb(0x64, 0xA8);

    // 2. Enable IRQ12 in the controller configuration byte
    waitWrite();
    io.outb(0x64, 0x20); // Request current controller command byte
    waitRead();
    const status = io.inb(0x60);

    waitWrite();
    io.outb(0x64, 0x60);          // Command: Write controller command byte
    waitWrite();
    io.outb(0x60, status | 0b10); // Set bit 1 to enable mouse IRQ12

    // 3. Reset mouse to defaults
    mouseWrite(0xF6);
    _ = mouseRead(); // Read ACK response byte (0xFA)

    // 4. Enable streaming mode
    mouseWrite(0xF4);
    _ = mouseRead(); // Read ACK response byte (0xFA)
}


// Mouse position state — clamped to screen bounds
pub var mouse_x: i32 = 400; // Default start x (screen center)
pub var mouse_y: i32 = 300; // Default start y (screen center)

// Dynamic resolution configuration based on VGA/VESA graphics state
const SCREEN_W: i32 = if (vga.graphics_mode) 1024 else 800;
const SCREEN_H: i32 = if (vga.graphics_mode) 768 else 600;

// Cursor dimensions in pixels
const CURSOR_W = 16;
const CURSOR_H = 16;

/// 16x16 Beamed Musical Notes Cursor Bitmap.
/// Hotspot is located at top-left corner (Column 15, Row 0).
/// Each u16 represents one horizontal pixel row:
///   • Bit 15 = Leftmost pixel (Column 0)
///   • Bit 0  = Rightmost pixel (Column 15)
///   • 1 = Draw opaque cursor pixel, 0 = Transparent background pixel
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

// Backing save buffer to store original display pixels under cursor (24bpp = 3 bytes/px)
var save_buffer: [CURSOR_W * CURSOR_H * 3]u8 = undefined;
var cursor_saved: bool = false;
var saved_x: i32 = 0;
var saved_y: i32 = 0;

/// Update current mouse coordinates from decoded packet motion deltas (dx, dy).
/// Note: PS/2 reports relative Y where positive movement goes upward,
/// so dy is subtracted to match display coordinates where Y increases downward.
pub fn updatePosition(dx: i8, dy: i8) void {
    mouse_x += @as(i32, dx);
    mouse_y -= @as(i32, dy); // Invert PS/2 Y delta to align with top-down screen Y

    // Retrieve active display bounds dynamically from framebuffer interface
    const max_w = @as(i32, @intCast(fb.fb_width));
    const max_h = @as(i32, @intCast(fb.fb_height));

    // Clamp coordinates within visible screen boundary
    if (mouse_x < 0) mouse_x = 0;
    if (mouse_y < 0) mouse_y = 0;

    if (mouse_x >= max_w - CURSOR_W) mouse_x = max_w - CURSOR_W;
    if (mouse_y >= max_h - CURSOR_H) mouse_y = max_h - CURSOR_H;
}

/// Backup original display framebuffer pixels directly underneath the cursor bounding box.
/// Saves raw 24bpp (BGR) bytes into `save_buffer` to allow clean erasure on cursor move.
fn saveCursor(x: i32, y: i32) void {
    const fb_ptr = @as([*]volatile u8, @ptrFromInt(@as(usize, 0x3E000000)));
    const stride = fb.fb_stride;

    var row: i32 = 0;
    while (row < CURSOR_H) : (row += 1) {
        var col: i32 = 0;
        while (col < CURSOR_W) : (col += 1) {
            const px = x + col;
            const py = y + row;

            // Compute Linear offsets: Framebuffer offset vs Local backing buffer offset
            const fb_offset = @as(usize, @intCast(py)) * stride + @as(usize, @intCast(px)) * 3;
            const buf_offset = @as(usize, @intCast(row * CURSOR_W + col)) * 3;

            // Copy 3 color channels (Blue, Green, Red)
            save_buffer[buf_offset + 0] = fb_ptr[fb_offset + 0];
            save_buffer[buf_offset + 1] = fb_ptr[fb_offset + 1];
            save_buffer[buf_offset + 2] = fb_ptr[fb_offset + 2];
        }
    }
    cursor_saved = true;
    saved_x = x;
    saved_y = y;
}

/// Restore original saved screen background pixels back to the framebuffer,
/// effectively hiding the rendered cursor bitmap without disturbing underlying content.
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

            // Write back saved pixel bytes
            fb_ptr[fb_offset + 0] = save_buffer[buf_offset + 0];
            fb_ptr[fb_offset + 1] = save_buffer[buf_offset + 1];
            fb_ptr[fb_offset + 2] = save_buffer[buf_offset + 2];
        }
    }
    cursor_saved = false;
}

/// Render the 16x16 cursor bitmap directly onto the active video framebuffer.
/// Backs up the underlying pixels first via `saveCursor()` to allow subsequent erasure.
pub fn drawCursor(x: i32, y: i32) void {
    if (!vga.graphics_mode) return; // Ignore draw requests when in text mode
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
            // Mask out individual bit from row (MSB first, col 0 = bit 15)
            const bit = @as(u16, 1) << @truncate(@as(u5, @intCast(15 - col)));
            if ((bitmap_row & bit) == 0) continue; // Skip transparent pixel bits

            const px = x + col;
            const py = y + row;

            // Bounds protection check
            if (px < 0 or py < 0 or px >= max_w or py >= max_h) continue;

            const fb_offset = @as(usize, @intCast(py)) * stride +
            @as(usize, @intCast(px)) * 3;

            // Write solid white color pixel (0xFFFFFF in 24bpp BGR format)
            fb_ptr[fb_offset + 0] = 0xFF; // Blue
            fb_ptr[fb_offset + 1] = 0xFF; // Green
            fb_ptr[fb_offset + 2] = 0xFF; // Red
        }
    }
}
