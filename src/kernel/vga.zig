// src/kernel/vga.zig
//
// Text output abstraction for both VGA text mode and framebuffer
// graphics mode.
//
// Provides:
//   • writeStringAt() — fixed-position text output
//   • writeString()   — cursor-driven text output
//   • writeRaw()      — output without implicit line management
//   • putChar()       — single-character output
//   • scroll()        — text scrolling support
//   • clearScreen()   — display clearing
//   • Cursor-management helpers
//
// When graphics_mode is false, output is written directly to the
// VGA text buffer at physical address 0xB8000.
//
// When graphics_mode is true, all rendering is forwarded to the
// framebuffer text renderer.
//
const conv = @import("convert.zig");
const io = @import("port_io.zig");
const serial = @import("drivers/serial.zig");
const fb = @import("framebuffer.zig");

/// VGA text buffer.
///
/// Each character cell occupies two bytes:
///   • Character value
///   • Colour attribute
const VGA = @as([*]volatile u16, @ptrFromInt(0xB8000));

/// Indicates whether framebuffer graphics mode is active.
///
/// When enabled, VGA buffer writes and hardware cursor updates are
/// replaced with framebuffer rendering operations.
pub var graphics_mode: bool = false;

/// VGA text-mode width in character cells.
const WIDTH = 80;

/// VGA text-mode height in character cells.
const HEIGHT = 25;

/// Current logical cursor row.
pub var cursor_row: usize = 0;

/// Current logical cursor column.
pub var cursor_col: usize = 0;

// -----------------------------------------------------------------------------
//  HIGH-LEVEL TEXT OUTPUT API
// -----------------------------------------------------------------------------

/// Write a string using the managed text cursor.
///
/// The output position is advanced automatically and scrolling is
/// performed as required.
pub fn writeString(s: []const u8, fg: u8, bg: u8) void {
    // serial.writeString(s);

    if (graphics_mode) {
        fb.writeString(s, fg, bg);
        return;
    }

    nextLine();

    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        putChar(s[i], fg, bg);
    }
}

/// Write text at a fixed screen position.
///
/// Unlike writeString(), this function does not modify the current
/// cursor location.
pub fn writeStringAt(
    row: u16,
    col: u16,
    s: []const u8,
    fg: u8,
    bg: u8,
) void {
    if (graphics_mode) {
        fb.writeStringAt(row, col, s, fg, bg);
        return;
    }

    const color =
    (@as(u16, bg) << 12) |
    (@as(u16, fg) << 8);

    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const pos =
        row * WIDTH +
        col +
        @as(u16, @intCast(i));

        VGA[pos] = color | s[i];
    }
}

/// Clear the entire display and reset cursor state.
///
/// Behaviour is automatically routed to the active display backend.
pub fn clearScreen(fg: u8, bg: u8) void {
    if (graphics_mode) {
        fb.clearScreen(fg, bg);
        return;
    }

    const color =
    (@as(u16, bg) << 12) |
    (@as(u16, fg) << 8);

    const blank = color | 0x20; // ASCII space

    var i: usize = 0;
    while (i < WIDTH * HEIGHT) : (i += 1) {
        VGA[i] = blank;
    }

    cursor_row = 0;
    cursor_col = 0;
}

/// Write a string without automatically moving to a new line.
///
/// Useful when output should continue from the current cursor
/// position.
pub fn writeRaw(s: []const u8, fg: u8, bg: u8) void {
    // serial.writeString(s);

    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        putChar(s[i], fg, bg);
    }
}

// -----------------------------------------------------------------------------
//  CHARACTER OUTPUT
// -----------------------------------------------------------------------------

/// Write a single character at the current cursor position.
///
/// Handles:
///   • Newline processing
///   • Line wrapping
///   • Screen scrolling
///   • Hardware cursor updates
///
/// Output is automatically routed to the framebuffer renderer when
/// graphics mode is active.
pub fn putChar(c: u8, fg: u8, bg: u8) void {
    if (graphics_mode) {
        fb.putChar(c, fg, bg);
        return;
    }

    const color =
    (@as(u16, bg) << 12) |
    (@as(u16, fg) << 8);

    if (c == '\n') {
        cursor_row += 1;
        cursor_col = 0;
    } else {
        VGA[cursor_row * WIDTH + cursor_col] = color | c;
        cursor_col += 1;
    }

    if (cursor_col >= WIDTH) {
        cursor_col = 0;
        cursor_row += 1;
    }

    if (cursor_row >= HEIGHT) {
        scroll();
        cursor_row = HEIGHT - 1;
    }

    updateCursorHardware();
}

// -----------------------------------------------------------------------------
//  SCROLLING AND LINE MANAGEMENT
// -----------------------------------------------------------------------------

/// Scroll the display upward by one text row.
///
/// Rows are shifted toward the top of the screen and the final row
/// is cleared for new output.
pub fn scroll() void {

    // Framebuffer mode provides its own scrolling implementation.
    if (graphics_mode) return;

    var row: usize = 1;

    while (row < HEIGHT) : (row += 1) {
        const src = row * WIDTH;
        const dst = (row - 1) * WIDTH;

        var col: usize = 0;
        while (col < WIDTH) : (col += 1) {
            VGA[dst + col] = VGA[src + col];
        }
    }

    // Clear the newly exposed final line.
    const last = (HEIGHT - 1) * WIDTH;

    var i: usize = 0;
    while (i < WIDTH) : (i += 1) {
        VGA[last + i] = 0x0720; // Space, light grey on black
    }
}

/// Move the cursor to the first available blank row.
///
/// If no blank rows remain, the display is scrolled and the cursor
/// is positioned on the final line.
pub fn nextLine() void {

    if (graphics_mode) return;

    var row: usize = 0;

    // Search for a completely empty row.
    while (row < HEIGHT) : (row += 1) {
        var empty = true;

        var col: usize = 0;
        while (col < WIDTH) : (col += 1) {
            const cell = VGA[row * WIDTH + col];

            // Character value occupies the low byte.
            const ch = @as(u8, @truncate(cell));

            if (ch != 0x20) {
                empty = false;
                break;
            }
        }

        if (empty) {
            cursor_row = row;
            cursor_col = 0;
            return;
        }
    }

    // No empty row exists.
    scroll();

    cursor_row = HEIGHT - 1;
    cursor_col = 0;
}

// -----------------------------------------------------------------------------
//  CURSOR MANAGEMENT
// -----------------------------------------------------------------------------

/// Set the logical cursor position.
///
/// Cursor state is synchronised with either the framebuffer console
/// or the VGA hardware cursor depending on the active display mode.
pub fn setCursor(row: usize, col: usize) void {
    cursor_row = row;
    cursor_col = col;

    if (graphics_mode) {
        fb.cursor_row = @intCast(row);
        fb.cursor_col = @intCast(col);
    } else {
        updateCursorHardware();
    }
}

/// Move the cursor one column to the left.
///
/// No wrapping occurs across line boundaries.
pub fn moveCursorLeft() void {
    const col = getCursorCol();
    const row = getCursorRow();

    if (col > 0) {
        setCursor(row, col - 1);
    }
}

/// Move the cursor one column to the right.
///
/// The cursor will not advance beyond the end of the current line.
pub fn moveCursorRight() void {
    if (cursor_col < WIDTH - 1) {
        cursor_col += 1;
        updateCursorHardware();
    }
}

/// Update the VGA hardware cursor.
///
/// The cursor position is written through the CRT controller's
/// index and data registers (ports 0x3D4 and 0x3D5).
pub fn updateCursorHardware() void {

    // Framebuffer mode uses a software-rendered cursor instead.
    if (graphics_mode) return;

    const pos: u16 =
    @intCast(cursor_row * WIDTH + cursor_col);

    io.outb(0x3D4, 0x0F);
    io.outb(0x3D5, @intCast(pos & 0xFF));

    io.outb(0x3D4, 0x0E);
    io.outb(0x3D5, @intCast((pos >> 8) & 0xFF));
}

// -----------------------------------------------------------------------------
//  DEBUGGING UTILITIES
// -----------------------------------------------------------------------------

/// Display a boot-progress marker in the upper-right corner.
///
/// Primarily used during early kernel initialisation to identify
/// which startup stage is currently executing.
pub fn step(n: u8) void {
    var buf: [4]u8 = undefined;

    const hex = conv.toHex(u8, n, &buf);

    writeStringAt(0, 72, "STEP: ", 15, 0);
    writeStringAt(0, 77, hex, 15, 0);
}

/// Display a hexadecimal dump of a sequence of 16-bit values.
///
/// Intended primarily for storage and memory debugging.
pub fn hexDump(data: []const u16, words_to_show: usize) void {
    var i: usize = 0;
    var buf: [16]u8 = undefined;

    writeString("\n--- Sector Hex Dump ---\n", 15, 0);

    while (i < words_to_show) : (i += 1) {
        const hex = conv.toHex(u16, data[i], &buf);

        writeString(hex, 11, 0); // Cyan
        writeString(" ", 15, 0);

        // Start a new line every 8 words (16 bytes).
        if ((i + 1) % 8 == 0) {
            writeString("\n", 15, 0);
        }
    }
}

// -----------------------------------------------------------------------------
//  CURSOR ACCESSORS
// -----------------------------------------------------------------------------

/// Return the current cursor column for the active display backend.
pub fn getCursorCol() usize {
    if (graphics_mode) return fb.cursor_col;
    return cursor_col;
}

/// Return the current cursor row for the active display backend.
pub fn getCursorRow() usize {
    if (graphics_mode) return fb.cursor_row;
    return cursor_row;
}
