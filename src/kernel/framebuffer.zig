// src/kernel/framebuffer.zig
//
// Framebuffer text renderer for VESA graphics mode.
// Draws characters as 8x16 pixel glyphs into a linear framebuffer.
// Provides the same interface as vga.zig so call sites can switch
// between text mode and graphics mode transparently.

const font = @import("font.zig");
const serial = @import("drivers/serial.zig");

// Framebuffer state — set once at boot from BootInfo
var fb_ptr:    [*]volatile u8 = undefined;
var fb_stride: u32 = 0;  // bytes per scanline
var fb_width:  u32 = 0;  // pixels per row
var fb_height: u32 = 0;  // pixels per column
var fb_bpp:    u32 = 0;  // bytes per pixel (3 for 24bpp, 4 for 32bpp)

// Text cursor position in character cells
pub var cursor_col: u32 = 0;
pub var cursor_row: u32 = 0;

// Derived text dimensions
var cols: u32 = 0;  // fb_width  / GLYPH_WIDTH
var rows: u32 = 0;  // fb_height / GLYPH_HEIGHT

// Colour palette — 4-bit VGA colour index to 24-bit BGR values
const palette: [16]u32 = .{
    0x000000, // 0  black
    0xAA0000, // 1  blue
    0x00AA00, // 2  green
    0x00FFFF, // 3  cyan
    0x0000AA, // 4  red
    0xAA00AA, // 5  magenta
    0x0055AA, // 6  brown
    0xAAAAAA, // 7  light grey
    0x555555, // 8  dark grey
    0xFF5555, // 9  bright blue
    0x55FF55, // 10 bright green
    0xFFFF55, // 11 bright cyan
    0x5555FF, // 12 bright red
    0xFF55FF, // 13 bright magenta
    0x55FFFF, // 14 yellow
    0xFFFFFF, // 15 white
};

/// Initialise the framebuffer renderer.
/// Must be called before any putChar/writeString calls.
pub fn init(addr: usize, stride: u32, width: u32, height: u32, bpp: u32) void {
    fb_ptr    = @as([*]volatile u8, @ptrFromInt(addr));
    fb_stride = stride;
    fb_width  = width;
    fb_height = height;
    fb_bpp    = bpp / 8;  // convert bits to bytes
    cols      = width  / font.GLYPH_WIDTH;
    rows      = height / font.GLYPH_HEIGHT;
    cursor_col = 0;
    cursor_row = 0;
}

/// Draw a single glyph at character cell (col, row) with given colours.
fn drawGlyph(char: u8, col: u32, row: u32, fg: u8, bg: u8) void {
    const fg_colour = palette[fg & 0x0F];
    const bg_colour = palette[bg & 0x0F];

    const px = col * font.GLYPH_WIDTH;   // pixel x start
    const py = row * font.GLYPH_HEIGHT;  // pixel y start

    var gy: u32 = 0;
    while (gy < font.GLYPH_HEIGHT) : (gy += 1) {
        const glyph_row = font.glyphs[@as(u32, char) * font.GLYPH_HEIGHT + gy];
        var gx: u32 = 0;
        while (gx < font.GLYPH_WIDTH) : (gx += 1) {
            // MSB = leftmost pixel
            const bit = @as(u8, 1) << @truncate(7 - gx);
            const colour = if ((glyph_row & bit) != 0) fg_colour else bg_colour;

            const offset = (py + gy) * fb_stride + (px + gx) * fb_bpp;
            fb_ptr[offset + 0] = @truncate(colour & 0xFF);         // B
            fb_ptr[offset + 1] = @truncate((colour >> 8)  & 0xFF); // G
            fb_ptr[offset + 2] = @truncate((colour >> 16) & 0xFF); // R
        }
    }
}

/// Scroll the screen up by one character row.
/// Scroll the screen up by one character row.
/// Scroll the screen up by one character row.
fn scroll() void {
    const copy_height = (rows - 1) * font.GLYPH_HEIGHT;
    const copy_size = copy_height * fb_stride;
    const src_offset = font.GLYPH_HEIGHT * fb_stride;

    // 1. Strip volatile using @volatileCast, then change the base type to u8 via @ptrCast
    const raw_fb = @as([*]u8, @ptrCast(@volatileCast(fb_ptr)));

    // 2. Define the destination and source memory windows
    const dest_slice = raw_fb[0..copy_size];
    const src_slice = raw_fb[src_offset .. src_offset + copy_size];

    // 3. Move the screen up safely using @memmove to handle the overlapping memory regions
    @memmove(dest_slice, src_slice);

    // 4. Clear the last row to black instantly
    const clear_start = (rows - 1) * font.GLYPH_HEIGHT * fb_stride;
    const clear_size = font.GLYPH_HEIGHT * fb_stride;
    const clear_slice = raw_fb[clear_start .. clear_start + clear_size];

    @memset(clear_slice, 0);
}

/// Write a single character at the current cursor position.
pub fn putChar(c: u8, fg: u8, bg: u8) void {
    serial.putChar(c);

    if (c == '\n') {
        cursor_col = 0;
        cursor_row += 1;
    } else if (c == '\r') {
        cursor_col = 0;
    } else {
        drawGlyph(c, cursor_col, cursor_row, fg, bg);
        cursor_col += 1;
        if (cursor_col >= cols) {
            cursor_col = 0;
            cursor_row += 1;
        }
    }

    if (cursor_row >= rows) {
        scroll();
        cursor_row = rows - 1;
    }
}

/// Write a string at the current cursor position.
pub fn writeString(s: []const u8, fg: u8, bg: u8) void {
    for (s) |c| putChar(c, fg, bg);
}

/// Write a string at a fixed character cell position.
pub fn writeStringAt(row: u16, col: u16, s: []const u8, fg: u8, bg: u8) void {
    var i: u32 = 0;
    while (i < s.len) : (i += 1) {
        drawGlyph(s[i], col + i, row, fg, bg);
    }
}

/// Clear the screen to background colour.
pub fn clearScreen(fg: u8, bg: u8) void {
    _ = fg;
    const bg_colour = palette[bg & 0x0F];
    var y: u32 = 0;
    while (y < fb_height) : (y += 1) {
        var x: u32 = 0;
        while (x < fb_width) : (x += 1) {
            const offset = y * fb_stride + x * fb_bpp;
            fb_ptr[offset + 0] = @truncate(bg_colour & 0xFF);
            fb_ptr[offset + 1] = @truncate((bg_colour >> 8) & 0xFF);
            fb_ptr[offset + 2] = @truncate((bg_colour >> 16) & 0xFF);
        }
    }
    cursor_col = 0;
    cursor_row = 0;
}

pub fn getRows() u32 { return rows; }
pub fn getCols() u32 { return cols; }

/// Draws or erases a solid line under the current character cell.
/// Set `visible` to true to show the cursor, or false to clear it.
pub fn setCursorVisible(visible: bool) void {
    if (cursor_col >= cols or cursor_row >= rows) return;

    const start_x = cursor_col * font.GLYPH_WIDTH;
    const start_y = cursor_row * font.GLYPH_HEIGHT;

    // Choose the color index: 15 (White) to draw, 0 (Black) to erase
    const colour_idx: u8 = if (visible) 15 else 0;
    const color = palette[colour_idx & 0x0F];

    var y = start_y + 14;
    while (y < start_y + 16) : (y += 1) {
        if (y >= fb_height) break;

        var x = start_x;
        while (x < start_x + font.GLYPH_WIDTH) : (x += 1) {
            if (x >= fb_width) break;

            const pixel_offset = (y * fb_stride) + (x * fb_bpp);

            if (fb_bpp == 4) {
                const ptr: *volatile u32 = @ptrCast(@alignCast(&fb_ptr[pixel_offset]));
                ptr.* = color;
            } else if (fb_bpp == 3) {
                fb_ptr[pixel_offset + 0] = @truncate(color & 0xFF);         // Blue
                fb_ptr[pixel_offset + 1] = @truncate((color >> 8) & 0xFF);  // Green
                fb_ptr[pixel_offset + 2] = @truncate((color >> 16) & 0xFF); // Red
            }
        }
    }
}
