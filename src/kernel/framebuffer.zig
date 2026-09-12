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
pub var fb_stride: u32 = 0;  // bytes per scanline
pub var fb_width:  u32 = 0;  // pixels per row
pub var fb_height: u32 = 0;  // pixels per column
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

var red_pos: u5 = 16;
var green_pos: u5 = 8;
var blue_pos: u5 = 0;

pub fn init(
    addr: usize,
    stride: u32,
    width: u32,
    height: u32,
    bpp: u32,
    r_pos: u64,
    g_pos: u64,
    b_pos: u64
) void {
    fb_ptr     = @as([*]volatile u8, @ptrFromInt(addr));
    fb_stride  = stride;
    fb_width   = width;
    fb_height  = height;
    fb_bpp     = bpp / 8;
    cols       = width / font.GLYPH_WIDTH;
    rows       = height / font.GLYPH_HEIGHT;

    red_pos   = @intCast(r_pos);
    green_pos = @intCast(g_pos);
    blue_pos  = @intCast(b_pos);

    cursor_col = 0;
    cursor_row = 0;
}

/// Internal helper to draw a single 32-bit color pixel at (x, y)
inline fn plotPixel(x: u32, y: u32, color: u32) void {
    const offset = y * fb_stride + x * fb_bpp;
    if (fb_bpp == 4) {
        const ptr: *volatile u32 = @ptrCast(@alignCast(&fb_ptr[offset]));
        ptr.* = color;
    } else if (fb_bpp == 3) {
        fb_ptr[offset + 0] = @truncate(color & 0xFF);
        fb_ptr[offset + 1] = @truncate((color >> 8) & 0xFF);
        fb_ptr[offset + 2] = @truncate((color >> 16) & 0xFF);
    }
}

/// Dynamic color packing based on VESA hardware info
fn packColor(r: u8, g: u8, b: u8) u32 {
    const red   = @as(u32, r) << red_pos;
    const green = @as(u32, g) << green_pos;
    const blue  = @as(u32, b) << blue_pos;
    return red | green | blue;
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
/// Clear the screen to background colour.
pub fn clearScreen(fg: u8, bg: u8) void {
    _ = fg;
    const raw_fb = @as([*]u8, @ptrCast(@volatileCast(fb_ptr)));

    // Fast path: clearing to black (0x00)
    if (bg == 0) {
        const total_bytes = fb_height * fb_stride;
        @memset(raw_fb[0..total_bytes], 0);
    } else {
        // Fill non-black background line by line
        const color = palette[bg & 0x0F];
        var y: u32 = 0;
        while (y < fb_height) : (y += 1) {
            var x: u32 = 0;
            while (x < fb_width) : (x += 1) {
                plotPixel(x, y, color);
            }
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


// -----------------------------------------------------------------------------
//  GRAPHICS PRIMITIVES & DRAWING HELPERS
// -----------------------------------------------------------------------------

/// Fills a rectangular region with a 32-bit packed color.
pub fn fillRect(x: u32, y: u32, width: u32, height: u32, color: u32) void {
    if (x >= fb_width or y >= fb_height) return;

    const max_x = @min(x + width, fb_width);
    const max_y = @min(y + height, fb_height);

    var py = y;
    while (py < max_y) : (py += 1) {
        var px = x;
        while (px < max_x) : (px += 1) {
            plotPixel(px, py, color);
        }
    }
}

/// Draws a 1-pixel-thick rectangle outline with a 32-bit packed color.
pub fn drawRectOutline(x: u32, y: u32, width: u32, height: u32, color: u32) void {
    if (width == 0 or height == 0) return;

    // Top and bottom horizontal borders
    var px = x;
    while (px < x + width and px < fb_width) : (px += 1) {
        if (y < fb_height) plotPixel(px, y, color);
        if (y + height - 1 < fb_height) plotPixel(px, y + height - 1, color);
    }

    // Left and right vertical borders
    var py = y;
    while (py < y + height and py < fb_height) : (py += 1) {
        if (x < fb_width) plotPixel(x, py, color);
        if (x + width - 1 < fb_width) plotPixel(x + width - 1, py, color);
    }
}

/// Renders raw 24-bit RGB pixel data onto the screen at (x, y).
pub fn drawImage(x: u32, y: u32, img_width: u32, img_height: u32, data: []const u8) void {
    var py: u32 = 0;
    while (py < img_height) : (py += 1) {
        if (y + py >= fb_height) break;

        var px: u32 = 0;
        while (px < img_width) : (px += 1) {
            if (x + px >= fb_width) break;

            const img_index = (py * img_width + px) * 3;
            if (img_index + 2 >= data.len) return;

            const r = data[img_index + 0];
            const g = data[img_index + 1];
            const b = data[img_index + 2];

            const color = packColor(r, g, b);
            plotPixel(x + px, y + py, color);
        }
    }
}

/// Renders text at exact pixel coordinates (x, y) rather than cell coordinates.
pub fn drawStringAtPixel(x: u32, y: u32, text: []const u8, fg_color: u32, bg_color: u32) void {
    var curr_x = x;
    for (text) |char| {
        if (curr_x + font.GLYPH_WIDTH > fb_width) break;

        var gy: u32 = 0;
        while (gy < font.GLYPH_HEIGHT) : (gy += 1) {
            if (y + gy >= fb_height) break;

            const glyph_row = font.glyphs[@as(u32, char) * font.GLYPH_HEIGHT + gy];
            var gx: u32 = 0;
            while (gx < font.GLYPH_WIDTH) : (gx += 1) {
                const bit = @as(u8, 1) << @truncate(7 - gx);
                const color = if ((glyph_row & bit) != 0) fg_color else bg_color;

                plotPixel(curr_x + gx, y + gy, color);
            }
        }
        curr_x += font.GLYPH_WIDTH;
    }
}
