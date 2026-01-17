// src/kernel/vga.zig
//
// Minimal VGA text‑mode driver for 80×25 mode.
// Provides:
//   • writeStringAt(row, col, text, fg, bg)
//   • writeString(text, fg, bg) with cursor tracking
//   • putChar()
//   • scroll()
//   • clearScreen()
//
// This is intentionally simple and synchronous — perfect for early kernel output.

const VGA = @as([*]volatile u16, @ptrFromInt(0xB8000));
const WIDTH = 80;
const HEIGHT = 25;

/// Global cursor position for writeString() and putChar()
pub var cursor_row: usize = 0;
pub var cursor_col: usize = 0;

/// Write a string at a fixed position (no cursor movement).
/// Colors: fg = foreground, bg = background (VGA 4‑bit each).
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

/// Scroll the screen up by one line.
/// Row 1 becomes row 0, row 2 becomes row 1, etc.
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

/// Write a single character at the current cursor position.
/// Handles newline, wrapping, and scrolling.
pub fn putChar(c: u8, fg: u8, bg: u8) void {
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
}

/// Write a string starting at the next available line.
/// Uses cursor tracking and putChar().
pub fn writeString(s: []const u8, fg: u8, bg: u8) void {
    nextLine();
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        putChar(s[i], fg, bg);
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

/// Clear the entire screen to the given fg/bg colors.
/// Resets cursor to (0,0).
pub fn clearScreen(fg: u8, bg: u8) void {
    const color = (@as(u16, bg) << 12) | (@as(u16, fg) << 8);
    const blank = color | 0x20; // space character

    var i: usize = 0;
    while (i < WIDTH * HEIGHT) : (i += 1) {
        VGA[i] = blank;
    }

    cursor_row = 0;
    cursor_col = 0;
}
