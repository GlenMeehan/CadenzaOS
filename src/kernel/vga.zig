// src/kernel/vga.zig
//
// Minimal VGA text‑mode driver for 80×25 mode.
// This module provides:
//   • writeStringAt(row, col, text, fg, bg)
//   • writeString(text, fg, bg) with cursor tracking
//   • putChar()
//   • scroll()
//   • clearScreen()
//   • cursor movement helpers
//
// This driver is intentionally simple and synchronous — ideal for early kernel output.
// All operations write directly to the VGA text buffer at 0xB8000.

const conv = @import("convert.zig");
const io = @import("port_io.zig");
const serial = @import("drivers/serial.zig");

// VGA text buffer (80×25 characters, 2 bytes per cell)
const VGA = @as([*]volatile u16, @ptrFromInt(0xB8000));

const WIDTH  = 80;
const HEIGHT = 25;

// Global cursor position used by writeString() and putChar()
pub var cursor_row: usize = 0;
pub var cursor_col: usize = 0;

// -----------------------------------------------------------------------------
//  HIGH‑LEVEL API
// -----------------------------------------------------------------------------

/// Write a string starting at the next available line.
/// Uses cursor tracking and putChar().
pub fn writeString(s: []const u8, fg: u8, bg: u8) void {
    //serial.writeString(s);
    nextLine();
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        putChar(s[i], fg, bg);
    }
}

/// Write a string at a fixed position (no cursor movement).
/// Colors: fg = foreground, bg = background (4‑bit each).
pub fn writeStringAt(
    row: u16,
    col: u16,
    s: []const u8,
    fg: u8,
    bg: u8,
) void {
    const color = (@as(u16, bg) << 12) | (@as(u16, fg) << 8);

    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const pos = row * WIDTH + col + @as(u16, @intCast(i));
        VGA[pos] = color | s[i];
    }
}

/// Clear the entire screen to the given fg/bg colors.
/// Resets cursor to (0,0).
pub fn clearScreen(fg: u8, bg: u8) void {
    const color = (@as(u16, bg) << 12) | (@as(u16, fg) << 8);
    const blank = color | 0x20; // space

    var i: usize = 0;
    while (i < WIDTH * HEIGHT) : (i += 1) {
        VGA[i] = blank;
    }

    cursor_row = 0;
    cursor_col = 0;
}

/// Write raw text using putChar() without moving to a new line first.
pub fn writeRaw(s: []const u8, fg: u8, bg: u8) void {
    //serial.writeString(s);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        putChar(s[i], fg, bg);
    }
}

// -----------------------------------------------------------------------------
//  CHARACTER OUTPUT
// -----------------------------------------------------------------------------

/// Write a single character at the current cursor position.
/// Handles newline, wrapping, and scrolling.
pub fn putChar(c: u8, fg: u8, bg: u8) void {
    serial.putChar(c);
    const color = (@as(u16, bg) << 12) | (@as(u16, fg) << 8);

    if (c == '\n') {
        cursor_row += 1;
        cursor_col = 0;
    } else {
        VGA[cursor_row * WIDTH + cursor_col] = color | c;
        cursor_col += 1;
    }

    // Wrap horizontally
    if (cursor_col >= WIDTH) {
        cursor_col = 0;
        cursor_row += 1;
    }

    // Scroll if needed
    if (cursor_row >= HEIGHT) {
        scroll();
        cursor_row = HEIGHT - 1;
    }

    updateCursorHardware();
}

// -----------------------------------------------------------------------------
//  SCROLLING & LINE MANAGEMENT
// -----------------------------------------------------------------------------

/// Scroll the screen up by one line.
/// Row 1 → row 0, row 2 → row 1, etc.
/// Last row is cleared.
pub fn scroll() void {
    // Shift rows upward
    var row: usize = 1;
    while (row < HEIGHT) : (row += 1) {
        const src = row * WIDTH;
        const dst = (row - 1) * WIDTH;

        var col: usize = 0;
        while (col < WIDTH) : (col += 1) {
            VGA[dst + col] = VGA[src + col];
        }
    }

    // Clear last row (light grey on black)
    const last = (HEIGHT - 1) * WIDTH;
    var i: usize = 0;
    while (i < WIDTH) : (i += 1) {
        VGA[last + i] = 0x0720; // space, fg=7, bg=0
    }
}

/// Move the cursor to the first empty line.
/// If no empty line exists, scroll the screen.
pub fn nextLine() void {
    var row: usize = 0;

    // Search for a fully blank row
    while (row < HEIGHT) : (row += 1) {
        var empty = true;

        var col: usize = 0;
        while (col < WIDTH) : (col += 1) {
            const cell = VGA[row * WIDTH + col];
            const ch = @as(u8, @truncate(cell)); // low byte = character

            if (ch != 0x20) { // not a space
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

    // No empty line → scroll
    scroll();
    cursor_row = HEIGHT - 1;
    cursor_col = 0;
}

// -----------------------------------------------------------------------------
//  CURSOR CONTROL (low‑level)
// -----------------------------------------------------------------------------

/// Set the cursor to an explicit (row, col) position.
pub fn setCursor(row: usize, col: usize) void {
    cursor_row = row;
    cursor_col = col;
    updateCursorHardware();
}

/// Move cursor left by one column (no wrapping).
pub fn moveCursorLeft() void {
    if (cursor_col > 0) {
        cursor_col -= 1;
        updateCursorHardware();
    }
}

/// Move cursor right by one column (no wrapping).
pub fn moveCursorRight() void {
    if (cursor_col < WIDTH - 1) {
        cursor_col += 1;
        updateCursorHardware();
    }
}

/// Update the VGA hardware cursor via ports 0x3D4/0x3D5.
pub fn updateCursorHardware() void {
    const pos: u16 = @intCast(cursor_row * WIDTH + cursor_col);

    io.outb(0x3D4, 0x0F);
    io.outb(0x3D5, @intCast(pos & 0xFF));

    io.outb(0x3D4, 0x0E);
    io.outb(0x3D5, @intCast((pos >> 8) & 0xFF));
}

// -----------------------------------------------------------------------------
//  DEBUG UTILITIES
// -----------------------------------------------------------------------------

/// Display a small "STEP: XX" indicator at the top‑right corner.
/// Useful for debugging early boot code.
pub fn step(n: u8) void {
    var buf: [4]u8 = undefined;
    const hex = conv.toHex(u8, n, &buf);
    writeStringAt(0, 72, "STEP: ", 15, 0);
    writeStringAt(0, 77, hex, 15, 0);
}

/// Hex‑dump a sequence of u16 words to the screen.
pub fn hexDump(data: []const u16, words_to_show: usize) void {
    var i: usize = 0;
    var buf: [16]u8 = undefined;

    writeString("\n--- Sector Hex Dump ---\n", 15, 0);

    while (i < words_to_show) : (i += 1) {
        const hex = conv.toHex(u16, data[i], &buf);
        writeString(hex, 11, 0); // Cyan
        writeString(" ", 15, 0);

        // New line every 8 words (16 bytes)
        if ((i + 1) % 8 == 0) writeString("\n", 15, 0);
    }
}
