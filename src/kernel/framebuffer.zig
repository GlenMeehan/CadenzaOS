// src/kernel/framebuffer.zig
//
// Framebuffer-based text renderer for VESA graphics modes.
//
// Characters are rendered using the built-in 8x16 bitmap font and
// written directly into a linear framebuffer. The public interface
// mirrors vga.zig so higher-level kernel code can switch between
// text-mode and graphics-mode output without modification.
//
const font = @import("font.zig");
const serial = @import("drivers/serial.zig");

// -----------------------------------------------------------------------------
//  FRAMEBUFFER STATE
// -----------------------------------------------------------------------------

/// Framebuffer base address supplied by BootInfo during startup.
var fb_ptr: [*]volatile u8 = undefined;

/// Number of bytes between the start of one scanline and the next.
pub var fb_stride: u32 = 0;

/// Framebuffer width in pixels.
pub var fb_width: u32 = 0;

/// Framebuffer height in pixels.
pub var fb_height: u32 = 0;

/// Bytes per pixel.
///
/// Typical values:
///   3 = 24-bit colour
///   4 = 32-bit colour
var fb_bpp: u32 = 0;

// -----------------------------------------------------------------------------
//  TEXT CURSOR STATE
// -----------------------------------------------------------------------------

/// Current text cursor column in character-cell coordinates.
pub var cursor_col: u32 = 0;

/// Current text cursor row in character-cell coordinates.
pub var cursor_row: u32 = 0;

// -----------------------------------------------------------------------------
//  DERIVED TEXT DIMENSIONS
// -----------------------------------------------------------------------------

/// Number of text columns that fit on the framebuffer.
var cols: u32 = 0;

/// Number of text rows that fit on the framebuffer.
var rows: u32 = 0;

// -----------------------------------------------------------------------------
//  VGA-COMPATIBLE COLOUR PALETTE
// -----------------------------------------------------------------------------

/// Mapping from 4-bit VGA colour indices to 24-bit RGB values.
///
/// This allows framebuffer text rendering to use the same colour
/// identifiers as the traditional VGA text renderer.
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

/// Colour channel bit positions supplied by VESA mode information.
///
/// These defaults match the common X8R8G8B8 layout but are replaced
/// during initialisation with values reported by the bootloader.
pub var red_pos: u5 = 16;
pub var green_pos: u5 = 8;
pub var blue_pos: u5 = 0;

/// Initialise framebuffer rendering state.
///
/// Must be called before any text output or pixel operations.
/// The supplied parameters are obtained from the bootloader's
/// framebuffer information structure.
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

    // Calculate the framebuffer's text dimensions based on the
    // fixed-size bitmap font.
    cols       = width / font.GLYPH_WIDTH;
    rows       = height / font.GLYPH_HEIGHT;

    // Record hardware-specific colour channel locations.
    red_pos   = @intCast(r_pos);
    green_pos = @intCast(g_pos);
    blue_pos  = @intCast(b_pos);

    // Begin text output at the top-left corner.
    cursor_col = 0;
    cursor_row = 0;
}

/// Write a single pixel to the framebuffer.
///
/// Supports both 24-bit and 32-bit framebuffer formats.
/// The colour value must already be packed into the format
/// expected by the active video mode.
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

/// Pack RGB colour components into the framebuffer's native pixel
/// format using the channel positions reported by the video mode.
pub fn packColor(r: u8, g: u8, b: u8) u32 {
    const red   = @as(u32, r) << red_pos;
    const green = @as(u32, g) << green_pos;
    const blue  = @as(u32, b) << blue_pos;
    return red | green | blue;
}

/// Render a single character glyph at the specified text cell.
///
/// The glyph bitmap is read from font.zig and expanded into pixels
/// within the framebuffer using the supplied foreground and
/// background VGA colour indices.
fn drawGlyph(char: u8, col: u32, row: u32, fg: u8, bg: u8) void {
    const fg_hex = palette[fg & 0x0F];
    const fg_colour = packColor(
        @truncate((fg_hex >> 16) & 0xFF),
                                @truncate((fg_hex >> 8) & 0xFF),
                                @truncate(fg_hex & 0xFF),
    );

    const bg_hex = palette[bg & 0x0F];
    const bg_colour = packColor(
        @truncate((bg_hex >> 16) & 0xFF),
                                @truncate((bg_hex >> 8) & 0xFF),
                                @truncate(bg_hex & 0xFF),
    );

    // Convert character-cell coordinates into framebuffer pixels.
    const px = col * font.GLYPH_WIDTH;
    const py = row * font.GLYPH_HEIGHT;

    var gy: u32 = 0;
    while (gy < font.GLYPH_HEIGHT) : (gy += 1) {

        // Each row of a glyph is stored as a single byte whose bits
        // represent the eight horizontal pixels.
        const glyph_row = font.glyphs[@as(u32, char) * font.GLYPH_HEIGHT + gy];

        var gx: u32 = 0;
        while (gx < font.GLYPH_WIDTH) : (gx += 1) {
            const bit = @as(u8, 1) << @truncate(7 - gx);
            const colour = if ((glyph_row & bit) != 0)
            fg_colour
            else
                bg_colour;

            plotPixel(px + gx, py + gy, colour);
        }
    }
}

/// Scroll the framebuffer contents upward by one text row.
///
/// The framebuffer is treated as a large pixel array. All scanlines
/// except the first character row are moved upward, and the newly
/// exposed bottom row is cleared.
fn scroll() void {
    const copy_height = (rows - 1) * font.GLYPH_HEIGHT;
    const copy_size = copy_height * fb_stride;
    const src_offset = font.GLYPH_HEIGHT * fb_stride;

    // Temporarily obtain a non-volatile view so bulk memory
    // operations can be performed efficiently.
    const raw_fb = @as([*]u8, @ptrCast(@volatileCast(fb_ptr)));

    // Define the destination and source framebuffer regions.
    const dest_slice = raw_fb[0..copy_size];
    const src_slice = raw_fb[src_offset .. src_offset + copy_size];

    // Move the framebuffer contents upward. @memmove() is required
    // because the source and destination ranges overlap.
    @memmove(dest_slice, src_slice);

    // Clear the newly exposed bottom text row.
    const clear_start = (rows - 1) * font.GLYPH_HEIGHT * fb_stride;
    const clear_size = font.GLYPH_HEIGHT * fb_stride;
    const clear_slice = raw_fb[clear_start .. clear_start + clear_size];

    @memset(clear_slice, 0);
}

/// Write a single character at the current cursor position.
///
/// Printable characters are rendered into the framebuffer while
/// control characters update cursor state as appropriate.
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

        // Automatically wrap at the right edge of the screen.
        if (cursor_col >= cols) {
            cursor_col = 0;
            cursor_row += 1;
        }
    }

    // Scroll once the cursor moves beyond the final visible row.
    if (cursor_row >= rows) {
        scroll();
        cursor_row = rows - 1;
    }
}

/// Write a string at the current cursor position using the supplied
/// foreground and background colours.
pub fn writeString(s: []const u8, fg: u8, bg: u8) void {
    for (s) |c| putChar(c, fg, bg);
}

/// Draw a string at a fixed text-cell position without modifying the
/// current cursor location.
pub fn writeStringAt(row: u16, col: u16, s: []const u8, fg: u8, bg: u8) void {
    var i: u32 = 0;
    while (i < s.len) : (i += 1) {
        drawGlyph(s[i], col + i, row, fg, bg);
    }
}

/// Clear the entire framebuffer and reset the text cursor.
///
/// A fast memset path is used when the requested background colour is
/// black, otherwise every pixel is explicitly redrawn.
pub fn clearScreen(fg: u8, bg: u8) void {
    _ = fg;

    const raw_fb = @as([*]u8, @ptrCast(@volatileCast(fb_ptr)));

    // Fast path for black backgrounds.
    if (bg == 0) {
        const total_bytes = fb_height * fb_stride;
        @memset(raw_fb[0..total_bytes], 0);
    } else {

        // Non-black clears must be performed pixel by pixel.
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

/// Return the number of visible text rows supported by the current
/// framebuffer configuration.
pub fn getRows() u32 { return rows; }

/// Return the number of visible text columns supported by the current
/// framebuffer configuration.
pub fn getCols() u32 { return cols; }

/// Draw or erase a simple text cursor at the current character cell.
///
/// The cursor is rendered as a solid underline occupying the bottom
/// two pixel rows of the active character cell.
pub fn setCursorVisible(visible: bool) void {
    if (cursor_col >= cols or cursor_row >= rows) return;

    const start_x = cursor_col * font.GLYPH_WIDTH;
    const start_y = cursor_row * font.GLYPH_HEIGHT;

    const colour_idx: u8 = if (visible) 15 else 0;
    const hex = palette[colour_idx & 0x0F];

    const color = packColor(
        @truncate((hex >> 16) & 0xFF),
                            @truncate((hex >> 8) & 0xFF),
                            @truncate(hex & 0xFF),
    );

    // Draw the underline across the bottom of the cell.
    var y = start_y + 14;
    while (y < start_y + 16) : (y += 1) {
        if (y >= fb_height) break;

        var x = start_x;
        while (x < start_x + font.GLYPH_WIDTH) : (x += 1) {
            if (x >= fb_width) break;
            plotPixel(x, y, color);
        }
    }
}

// -----------------------------------------------------------------------------
//  GRAPHICS PRIMITIVES & DRAWING HELPERS
// -----------------------------------------------------------------------------

/// Fill a rectangular region with a packed framebuffer colour.
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

/// Draw a one-pixel-wide rectangular outline.
pub fn drawRectOutline(x: u32, y: u32, width: u32, height: u32, color: u32) void {
    if (width == 0 or height == 0) return;

    // Draw the top and bottom borders.
    var px = x;
    while (px < x + width and px < fb_width) : (px += 1) {
        if (y < fb_height) plotPixel(px, y, color);
        if (y + height - 1 < fb_height) plotPixel(px, y + height - 1, color);
    }

    // Draw the left and right borders.
    var py = y;
    while (py < y + height and py < fb_height) : (py += 1) {
        if (x < fb_width) plotPixel(x, py, color);
        if (x + width - 1 < fb_width) plotPixel(x + width - 1, py, color);
    }
}

/// Render raw 24-bit RGB image data into the framebuffer.
///
/// The input buffer is expected to contain tightly packed RGB triplets
/// in row-major order.
pub fn drawImage(x: u32, y: u32, img_width: u32, img_height: u32, data: []const u8) void {
    const expected_len: usize = @as(usize, img_width) * @as(usize, img_height) * 3;
    if (data.len < expected_len) return;

    var py: u32 = 0;
    while (py < img_height) : (py += 1) {
        var px: u32 = 0;
        while (px < img_width) : (px += 1) {
            const idx: usize =
            @as(usize, py) * @as(usize, img_width) * 3 +
            @as(usize, px) * 3;

            const r: u8 = data[idx + 0];
            const g: u8 = data[idx + 1];
            const b: u8 = data[idx + 2];

            plotPixel(x + px, y + py, packColor(r, g, b));
        }
    }
}

/// Render a 24-bit RGB image using nearest-neighbour scaling.
///
/// Each destination pixel maps to the closest source pixel. This
/// approach is simple and fast, making it suitable for early-kernel
/// graphics where image quality is less important than performance.
pub fn drawImageScaled(
    x: u32, y: u32,
    src_width: u32, src_height: u32,
    dest_width: u32, dest_height: u32,
    data: []const u8,
) void {
    const expected_len: usize = @as(usize, src_width) * @as(usize, src_height) * 3;
    if (data.len < expected_len) return;
    if (dest_width == 0 or dest_height == 0) return;

    var dy: u32 = 0;
    while (dy < dest_height) : (dy += 1) {

        // Map destination coordinates back into source space.
        const sy = (dy * src_height) / dest_height;

        var dx: u32 = 0;
        while (dx < dest_width) : (dx += 1) {
            const sx = (dx * src_width) / dest_width;

            const idx: usize =
            @as(usize, sy) * @as(usize, src_width) * 3 +
            @as(usize, sx) * 3;

            const r: u8 = data[idx + 0];
            const g: u8 = data[idx + 1];
            const b: u8 = data[idx + 2];

            plotPixel(x + dx, y + dy, packColor(r, g, b));
        }
    }
}

/// Render text at exact pixel coordinates rather than text-cell
/// coordinates.
///
/// Unlike writeStringAt(), this function is intended for graphical
/// interfaces where text must be positioned with pixel precision.
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
                const color = if ((glyph_row & bit) != 0)
                fg_color
                else
                    bg_color;

                plotPixel(curr_x + gx, y + gy, color);
            }
        }

        // Advance to the next character position.
        curr_x += font.GLYPH_WIDTH;
    }
}

/// Write a hexadecimal value to the serial console.
///
/// Intended for low-level debugging where framebuffer output may not
/// yet be available or reliable.
fn printHex(label: []const u8, value: usize) void {
    const hex_chars = "0123456789ABCDEF";

    serial.writeString(label);
    serial.writeString(": 0x");

    var i: usize = 16;
    while (i > 0) {
        i -= 1;

        const nibble: u8 = @truncate((value >> @intCast(i * 4)) & 0xF);
        serial.putChar(hex_chars[nibble]);
    }

    serial.writeString("\n");
}

/// Halt the processor indefinitely.
///
/// Useful as a final error path when execution cannot safely continue.
pub fn pause() void {
    while (true) {
        asm volatile ("hlt");
    }
}

/// Convert a VGA palette index into a colour value suitable for the
/// current framebuffer pixel format.
///
/// The returned value is already packed using the active hardware
/// colour-channel layout.
pub fn paletteColor(idx: u8) u32 {
    const hex = palette[idx & 0x0F];

    return packColor(
        @truncate((hex >> 16) & 0xFF),
                     @truncate((hex >> 8) & 0xFF),
                     @truncate(hex & 0xFF),
    );
}
