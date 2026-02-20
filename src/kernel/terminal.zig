// src/kernel/terminal.zig
const vga = @import("vga.zig");
const conv = @import("convert.zig");
const std = @import("std");
const KeyEvent = @import("inputs/key_event.zig").KeyEvent;
const SpecialKey = @import("inputs/key_event.zig").SpecialKey;
const mem = @import("memory.zig");
const config = @import("config.zig");

const MAX_LINE = config.TERMINAL_LINE_SIZE;
const MAX_HISTORY = 32;

var line_buffer: [MAX_LINE]u8 = undefined;
var line_len: usize = 0;
pub var line_ready = std.atomic.Value(bool).init(false);
var cursor_row: usize = 0; // current row on screen for input line
var prompt_start: usize = 9;
var cursor_pos: usize = 0;    // position within the input line

// Command history storage
var history: [MAX_HISTORY][MAX_LINE]u8 = undefined;
pub var history_len: usize = 0;    // how many entries are valid
var history_head: usize = 0;   // next slot to write into

// Index into history while browsing
// -1 means: not currently browsing history
var history_index: isize = -1;

// Scratch buffer for the line being typed while browsing history
var saved_line: [MAX_LINE]u8 = undefined;
var saved_line_len: usize = 0;


pub fn processChar(ch: u8) void {
    // Backspace
    if (ch == 0x08) {
        if (cursor_pos > 0) {
            cursor_pos -= 1;
            line_len -= 1;

            vga.moveCursorLeft();
            vga.putChar(' ', 15, 0);
            vga.moveCursorLeft();
        }
        return;
    }

    // Enter
    if (ch == '\n' or ch == '\r') {
        line_ready.store(true, .release);
        vga.putChar('\n', 15, 0);
        return;
    }

    // Printable
    if (isPrintable(ch)) {
        if (line_len >= MAX_LINE) return;

        // Insert at end only (for now)
        line_buffer[line_len] = ch;
        line_len += 1;
        cursor_pos = line_len;

        // DO NOT TOUCH vga.cursor_col HERE
        vga.putChar(ch, 15, 0);
    }
}


fn isPrintable(ch: u8) bool {
    return ch >= 32 and ch < 127;
}

pub fn takeLine() ?[]const u8 {
    if (!line_ready.load(.acquire)) return null;
    return line_buffer[0..line_len];
}

pub fn consumeLine() void {
    line_len = 0;
    cursor_pos = 0;
    history_index = -1;
    line_ready.store(false, .release);
}


pub fn commitHistory() void {
    // Do not store empty lines
    if (line_len == 0) return;

    // Copy current line into history ring buffer
    const dst = history_head;
    @memcpy(history[dst][0..line_len], line_buffer[0..line_len]);

    // Optionally null-terminate (useful later)
    if (line_len < MAX_LINE) {
        history[dst][line_len] = 0;
    }

    // Advance ring buffer
    history_head = (history_head + 1) % MAX_HISTORY;

    if (history_len < MAX_HISTORY) {
        history_len += 1;
    }
}


pub fn handleKeyEvent(ev: KeyEvent) void {
    switch (ev) {
        .char => |c| {
            switch (c) {
                0x01 => moveCursorToStart(), // Ctrl-A
                0x05 => moveCursorToEnd(),   // Ctrl-E
                0x15 => killToStart(),       // Ctrl-U
                0x0B => killToEnd(),         // Ctrl-K
                0x03 => abortLine(),         // Ctrl-C
                0x0C => clearScreen(),       // Ctrl-L
                0x17 => deletePreviousWord(), // Ctrl-W

                else => processChar(c),
            }
        },
        .special => |k| switch (k) {
            .Left => moveLeft(),
            .Right => moveRight(),
            .Up => historyUp(),
            .Down => historyDown(),
            .Home => moveCursorToStart(),
            .End => moveCursorToEnd(),
            .Escape => cancelLine(),
            .Tab => insertTab(),
            .Delete => deleteUnderCursor(),
        },
    }
}

fn setCursorToLogical() void {
    vga.setCursor(cursor_row, prompt_start + cursor_pos);
}

fn redrawLine() void {
    // 1. Clear only the visible part of the line
    var i: usize = 0;
    while (i < line_len + 1) : (i += 1) { // +1 clears leftover char
        vga.setCursor(cursor_row, prompt_start + i);
        vga.putChar(' ', 15, 0);
    }

    // 2. Draw the current buffer
    i = 0;
    while (i < line_len) : (i += 1) {
        vga.setCursor(cursor_row, prompt_start + i);
        vga.putChar(line_buffer[i], 15, 0);
    }

    // 3. Restore cursor position
    setCursorToLogical();
}

fn moveLeft() void {
    if (cursor_pos == 0) return;

    cursor_pos -= 1;
    vga.setCursor(vga.cursor_row, prompt_start + cursor_pos);
}

fn moveRight() void {
    if (cursor_pos == line_len) return;

    cursor_pos += 1;
    vga.setCursor(vga.cursor_row, prompt_start + cursor_pos);
}

fn cancelLine() void {
    line_len = 0;
    cursor_pos = 0;
    redrawLine();
}

fn insertTab() void {
    const TAB_SIZE: u8 = 4;
    var i: u8 = 0;
    while (i < TAB_SIZE and line_len < MAX_LINE) : (i += 1) {
        vga.putChar(' ', 15, 0);
        line_buffer[line_len] = ' ';
        line_len += 1;
        cursor_pos += 1;
        vga.cursor_col = prompt_start + cursor_pos;
    }
}

fn moveCursorToStart() void {
    cursor_pos = 0;
    setCursorToLogical();
}

fn moveCursorToEnd() void {
    cursor_pos = line_len;
    setCursorToLogical();
}

fn killToStart() void {
    const old_len = line_len;

    // Shift everything right of cursor to the start
    var i: usize = 0;
    while (cursor_pos + i < line_len) : (i += 1) {
        line_buffer[i] = line_buffer[cursor_pos + i];
    }

    line_len -= cursor_pos;
    cursor_pos = 0;

    // Clear old visible region
    var j: usize = 0;
    while (j < old_len + 1) : (j += 1) {
        vga.setCursor(cursor_row, prompt_start + j);
        vga.putChar(' ', 15, 0);
    }

    redrawLine();
}

fn killToEnd() void {
    const old_len = line_len;

    line_len = cursor_pos;

    // Clear old visible region
    var j: usize = 0;
    while (j < old_len + 1) : (j += 1) {
        vga.setCursor(cursor_row, prompt_start + j);
        vga.putChar(' ', 15, 0);
    }

    redrawLine();
}

fn abortLine() void {
    cancelLine();
    vga.putChar('\n', 15, 0);
    line_ready.store(true, .release);
}

fn clearScreen() void {
    vga.clearScreen(15, 0);
    vga.cursor_col = prompt_start + cursor_pos + 1;
    vga.updateCursorHardware();
    vga.writeString("Cadenza> ",3, 0);
}

fn deleteUnderCursor() void {
    if (cursor_pos >= line_len) return;

    // Shift buffer left
    var i: usize = cursor_pos;
    while (i + 1 < line_len) : (i += 1) {
        line_buffer[i] = line_buffer[i + 1];
    }
    line_len -= 1;

    redrawLine();
}


fn loadHistoryLine() void {
    // Only proceed if browsing
    if (history_index < 0) return;

    // Clear current input line visually
    var i: usize = 0;
    while (i < line_len) : (i += 1) {
        vga.setCursor(cursor_row, prompt_start + i);
        vga.putChar(' ', 15, 0);
    }

    // Compute safe signed index
    const head: isize = @intCast(history_head);
    const max:  isize = @intCast(MAX_HISTORY);
    const hidx: isize = head + max - 1 - history_index;

    // Wrap modulo safely
    const wrapped: isize = @mod(hidx, max);

    // Final index for array
    const idx: usize = @intCast(wrapped);

    // Grab the history entry
    const src = history[idx];

    // Copy into line buffer
    var new_len: usize = 0;
    while (new_len < MAX_LINE and src[new_len] != 0) : (new_len += 1) {}
    line_len = new_len;
    cursor_pos = line_len;

    i = 0;
    while (i < line_len) : (i += 1) {
        line_buffer[i] = src[i];
    }

    // Redraw line
    redrawLine();

    // Set cursor at end
    vga.setCursor(cursor_row, prompt_start + cursor_pos);
}

pub fn startNewLine() void {
    cursor_pos = 0;
    line_len = 0;
    prompt_start = vga.cursor_col;
    cursor_row = vga.cursor_row;   // <-- absolutely required
}

fn historyUp() void {
    if (history_len == 0) return;

    if (history_index == -1) {
        // First time entering history browsing
        saved_line_len = line_len;
        @memcpy(saved_line[0..line_len], line_buffer[0..line_len]);
        history_index = 0;
    } else if (history_index + 1 < history_len) {
        history_index += 1;
    }

    loadHistoryLine();
}

fn historyDown() void {
    if (history_index == -1) return;

    if (history_index == 0) {
        // Restore the partially typed line
        var i: usize = 0;
        while (i < line_len) : (i += 1) {
            vga.setCursor(cursor_row, prompt_start + i);
            vga.putChar(' ', 15, 0);
        }

        line_len = saved_line_len;
        cursor_pos = line_len;
        @memcpy(line_buffer[0..line_len], saved_line[0..line_len]);

        // Redraw
        redrawLine();

        vga.setCursor(cursor_row, prompt_start + cursor_pos);

        history_index = -1;
    } else {
        history_index -= 1;
        loadHistoryLine();
    }
}
fn deletePreviousWord() void {
    if (cursor_pos == 0) return;

    const old_len = line_len;

    // 1. Find the start of the word to delete
    var start = cursor_pos;

    // Skip spaces before cursor
    while (start > 0 and line_buffer[start - 1] == ' ') {
        start -= 1;
    }

    // Skip the word characters
    while (start > 0 and line_buffer[start - 1] != ' ') {
        start -= 1;
    }

    // 2. Compute how many characters to remove
    const count = cursor_pos - start;

    // 3. Shift the rest of the buffer left
    var i: usize = start;
    while (i + count < line_len) : (i += 1) {
        line_buffer[i] = line_buffer[i + count];
    }

    line_len -= count;
    cursor_pos = start;

    // 4. Clear the old visible region
    var j: usize = 0;
    while (j < old_len + 1) : (j += 1) {
        vga.setCursor(cursor_row, prompt_start + j);
        vga.putChar(' ', 15, 0);
    }

    // 5. Redraw the new line
    redrawLine();
}

pub fn getHistoryEntry(n: usize) ?[]const u8 {
    // n = 0 → oldest
    // n = history_len-1 → newest
    if (n >= history_len) return null;

    const idx =
    (history_head + MAX_HISTORY - history_len + n) % MAX_HISTORY;

    const entry = history[idx];

    var len: usize = 0;
    while (len < MAX_LINE and entry[len] != 0) : (len += 1) {}

    return entry[0..len];
}
