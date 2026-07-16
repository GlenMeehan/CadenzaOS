// src/kernel/terminal.zig
//
// Line-editing and command input for the kernel terminal.
//
// Responsibilities:
//  - Maintain an editable input line (buffer, cursor, history)
//  - Render the line in "Canvas" mode on the first row (with ghost predictions)
//  - Fall back to "Stream" mode (hardware-driven) after wrapping
//  - Expose a simple API to the shell: startNewLine, handleKeyEvent, takeLine, consumeLine
//
// Important invariants:
//  - Canvas mode: input line is on a single row, ghost text is visible, redrawLine() is used.
//  - Stream mode: after wrapping, hardware VGA putChar() drives display; redrawLine() must not
//    touch wrapped rows. Ghost text is disabled in this mode.

const vga = @import("vga.zig");
const conv = @import("convert.zig");
const std = @import("std");
const KeyEvent = @import("inputs/key_event.zig").KeyEvent;
const SpecialKey = @import("inputs/key_event.zig").SpecialKey;
const mem = @import("memory.zig");
const config = @import("config.zig");
const keyboard = @import("inputs/keyboard.zig");
const scheduler = @import("scheduler.zig");
const fb = @import("framebuffer.zig");

const MAX_LINE = config.TERMINAL_LINE_SIZE;
const MAX_HISTORY = 32;

// -----------------------------------------------------------------------------
//  LINE STATE
// -----------------------------------------------------------------------------

var line_buffer: [MAX_LINE]u8 = undefined;
var line_len: usize = 0;
pub var line_ready = std.atomic.Value(bool).init(false);

// Screen position of the current input line
var cursor_row: usize = 0;      // row on screen where the input line lives
var prompt_start: usize = 9;    // column where the prompt starts
var cursor_pos: usize = 0;      // logical position within the input line

// We treat the row where startNewLine() was called as the "Canvas row".
var canvas_row: usize = 0;

// -----------------------------------------------------------------------------
//  HISTORY STATE
// -----------------------------------------------------------------------------

var history: [MAX_HISTORY][MAX_LINE]u8 = undefined;
pub var history_len: usize = 0;     // how many entries are valid
var history_head: usize = 0;        // next slot to write into

// Index into history while browsing
// -1 means: not currently browsing history
var history_index: isize = -1;

// Scratch buffer for the line being typed while browsing history
var saved_line: [MAX_LINE]u8 = undefined;
var saved_line_len: usize = 0;

// -----------------------------------------------------------------------------
//  PREDICTION HOOK
// -----------------------------------------------------------------------------

pub const PredictorFn = *const fn (input: []const u8) []const u8;

// This is the "slot" where the shell will plug in its the Composer
var external_predictor: ?PredictorFn = null;

pub fn setPredictor(func: PredictorFn) void {
    external_predictor = func;
}

// -----------------------------------------------------------------------------
//  MODE HELPERS (Canvas vs Stream)
// -----------------------------------------------------------------------------

fn inCanvasMode() bool {
    if (cursor_row != canvas_row) return false;
    const max_rows: usize = if (vga.graphics_mode) @as(usize, fb.getRows()) else 25;
    if (cursor_row >= max_rows) return false;

    // Dynamically check against the total column width minus 1
    const max_cols = if (vga.graphics_mode) @as(usize, fb.getCols()) else 80;
    return prompt_start + line_len < (max_cols - 1);
}

fn inStreamMode() bool {
    return !inCanvasMode();
}

// -----------------------------------------------------------------------------
//  PUBLIC API
// -----------------------------------------------------------------------------

pub fn processChar(ch: u8) void {
    // Backspace
    if (ch == 0x08) {
        if (cursor_pos > 0) {
            cursor_pos -= 1;
            line_len -= 1;

            if (inCanvasMode()) {
                redrawLine();
            } else {
                // Stream mode backspace
                const current_col = if (vga.graphics_mode) fb.cursor_col else vga.cursor_col;
                const current_row = if (vga.graphics_mode) fb.cursor_row else vga.cursor_row;

                if (current_col > 0) {
                    vga.setCursor(current_row, current_col - 1);
                    vga.putChar(' ', 15, 0);
                    vga.setCursor(current_row, current_col - 1);
                }
            }
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

        // Update logical buffer
        line_buffer[line_len] = ch;
        line_len += 1;
        cursor_pos = line_len;

        if (inCanvasMode()) {
            // Canvas mode: redraw the whole line + ghost text on the single row.
            redrawLine();
        } else {
            // Stream mode: let hardware handle wrapping/scrolling.
            vga.putChar(ch, 15, 0);
        }
    }
}

fn isPrintable(ch: u8) bool {
    return ch >= 32 and ch < 127;
}

pub fn takeLine() []const u8 {
    while (true) {
        // 1. First, drain the raw ring buffer keys into the line buffer
        //    (Show the solid cursor right before we wait or poll for characters)
        if (vga.graphics_mode) fb.setCursorVisible(true);

        pollKeyboard();

        // 2. Erase the cursor immediately once a key lands, so text rendering doesn't smear it
        //if (vga.graphics_mode) fb.setCursorVisible(false);

        // 3. Check if a full line is ready (user pressed Enter)
        if (line_ready.load(.acquire)) {
            return line_buffer[0..line_len];
        }

        // 4. The line isn't ready. Stop spinning!
        if (scheduler.manager.tasks[0]) |*shell_task| {
            shell_task.state = .Ready;
        }

        // 5. Immediately give up the rest of our time slot.
        scheduler.manager.yield();
    }
}

/// Drains all characters currently waiting in the keyboard's circular buffer
/// and processes them through the terminal's line-editor and UI state machine.
pub fn pollKeyboard() void {
    // Continuously pop from the ring buffer until it returns null (empty)
    while (keyboard.readChar()) |ch| {
        // Feed the raw character to your existing line processor
        processChar(ch);
    }
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
    _ = mem.memcpy(history[dst][0..line_len].ptr, line_buffer[0..line_len].ptr, line_len);

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
    asm volatile ("cli"); // Guard the state machine change
    switch (ev) {
        .char => |c| {
            switch (c) {
                0x01 => moveCursorToStart(),   // Ctrl-A
                0x05 => moveCursorToEnd(),     // Ctrl-E
                0x15 => killToStart(),         // Ctrl-U
                0x0B => killToEnd(),           // Ctrl-K
                0x03 => abortLine(),           // Ctrl-C
                0x0C => clearScreen(),         // Ctrl-L
                0x17 => deletePreviousWord(),  // Ctrl-W
                else => processChar(c),
            }
        },
        .special => |k| switch (k) {
            .Left   => moveLeft(),
            .Right  => moveRight(),
            .Up     => historyUp(),
            .Down   => historyDown(),
            .Home   => moveCursorToStart(),
            .End    => moveCursorToEnd(),
            .Escape => cancelLine(),
            .Tab    => insertTab(),
            .Delete => deleteUnderCursor(),
        },
    }
    asm volatile ("sti"); // Restore preemption
}

pub fn startNewLine() void {
    cursor_pos = 0;
    line_len = 0;

    // Capture the current VGA cursor as the start of our Canvas line.
    prompt_start = vga.getCursorCol();
    cursor_row = vga.getCursorRow();
    canvas_row = cursor_row;
}

pub fn getHistoryEntry(n: usize) ?[]const u8 {
    // n = 0 → oldest
    // n = history_len-1 → newest
    if (n >= history_len) return null;

    const idx = (history_head + MAX_HISTORY - history_len + n) % MAX_HISTORY;
    const entry = history[idx];

    var len: usize = 0;
    while (len < MAX_LINE and entry[len] != 0) : (len += 1) {}

    return entry[0..len];
}

pub fn refresh() void {
    // Only meaningful in Canvas mode; in Stream mode we do nothing to avoid
    // overwriting wrapped rows.
    redrawLine();
}

// -----------------------------------------------------------------------------
//  CURSOR & RENDERING HELPERS
// -----------------------------------------------------------------------------

fn setCursorToLogical() void {
    vga.setCursor(cursor_row, prompt_start + cursor_pos);
}

fn clearCanvasRegion() void {
    const max_cols = if (vga.graphics_mode) @as(usize, fb.getCols()) else 80;
    var col: usize = prompt_start;
    while (col < (max_cols - 1)) : (col += 1) {
        vga.setCursor(cursor_row, col);
        vga.putChar(' ', 15, 0);
    }
}

fn drawRealTextOnCanvas() void {
    const max_cols = if (vga.graphics_mode) @as(usize, fb.getCols()) else 80;
    var i: usize = 0;
    while (i < line_len) : (i += 1) {
        const target_col = prompt_start + i;
        if (target_col >= (max_cols - 1)) break;

        vga.setCursor(cursor_row, target_col);
        vga.putChar(line_buffer[i], 15, 0);
    }
}

fn drawGhostText() void {
    if (cursor_pos != line_len) return;
    if (!inCanvasMode()) return;

    const prediction = getPrediction(line_buffer[0..line_len]);
    if (prediction.len == 0) return;

    const max_cols = if (vga.graphics_mode) @as(usize, fb.getCols()) else 80;
    var j: usize = 0;
    while (j < prediction.len) : (j += 1) {
        const ghost_col = prompt_start + line_len + j;
        if (ghost_col >= (max_cols - 1)) break;

        vga.setCursor(cursor_row, ghost_col);
        vga.putChar(prediction[j], 8, 0);
    }
}

fn redrawLine() void {
    // Redraw is only safe/meaningful in Canvas mode.
    if (!inCanvasMode()) return;

    // TEMPORARY SAFETY GUARD (Adjust if your graphics canvas supports more rows)
    const max_rows = if (vga.graphics_mode) @as(usize, fb.getRows()) else 25;
    if (cursor_row >= max_rows) return;

    // Turn the cursor off before rendering new letters so it doesn't leave ghosts
    if (vga.graphics_mode) fb.setCursorVisible(false);

    clearCanvasRegion();
    drawRealTextOnCanvas();
    drawGhostText();
    setCursorToLogical();
}

// -----------------------------------------------------------------------------
//  CURSOR MOVEMENT & EDITING
// -----------------------------------------------------------------------------

fn moveLeft() void {
    if (cursor_pos == 0) return;

    cursor_pos -= 1;
    setCursorToLogical();
}

fn moveRight() void {
    if (cursor_pos < line_len) {
        // Normal movement within the line
        cursor_pos += 1;
        setCursorToLogical();
        redrawLine();
        return;
    }

    // At the end of the line? Check for prediction!
    const prediction = getPrediction(line_buffer[0..line_len]);
    if (prediction.len > 0) {
        // Copy prediction into the real buffer
        for (prediction) |char| {
            if (line_len < MAX_LINE) {
                line_buffer[line_len] = char;
                line_len += 1;
                cursor_pos += 1;
            }
        }
    }

    setCursorToLogical();
    redrawLine();
}

fn cancelLine() void {
    line_len = 0;
    cursor_pos = 0;
    redrawLine();
}

fn insertTab() void {
    const prediction = getPrediction(line_buffer[0..line_len]);

    // If a prediction exists, Tab accepts it instead of indenting
    if (prediction.len > 0) {
        acceptPrediction(prediction);
    } else {
        // Fallback to original tab logic (4 spaces)
        const TAB_SIZE: u8 = 4;
        var i: u8 = 0;
        while (i < TAB_SIZE and line_len < MAX_LINE) : (i += 1) {
            line_buffer[line_len] = ' ';
            line_len += 1;
            cursor_pos += 1;
        }
        redrawLine();
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
    vga.setCursor(0, 0);
    vga.writeString("Cadenza> ", 3, 0);

    // Anchor our input tracking exactly where the prompt finished printing
    prompt_start = if (vga.graphics_mode) fb.cursor_col else vga.cursor_col;
    cursor_row = if (vga.graphics_mode) fb.cursor_row else vga.cursor_row;
    canvas_row = cursor_row;
    cursor_pos = 0;
    line_len = 0;
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

// -----------------------------------------------------------------------------
//  HISTORY BROWSING
// -----------------------------------------------------------------------------

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

fn historyUp() void {
    if (history_len == 0) return;

    if (history_index == -1) {
        // First time entering history browsing
        saved_line_len = line_len;
        _ = mem.memcpy(saved_line[0..line_len].ptr, line_buffer[0..line_len].ptr, line_len);
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
        _ = mem.memcpy(line_buffer[0..line_len].ptr, saved_line[0..line_len].ptr, line_len);

        // Redraw
        redrawLine();
        vga.setCursor(cursor_row, prompt_start + cursor_pos);

        history_index = -1;
    } else {
        history_index -= 1;
        loadHistoryLine();
    }
}

// -----------------------------------------------------------------------------
//  PREDICTION
// -----------------------------------------------------------------------------

fn getPrediction(input: []const u8) []const u8 {
    if (external_predictor) |predict| {
        return predict(input);
    }
    return "";
}

fn acceptPrediction(prediction: []const u8) void {
    for (prediction) |char| {
        if (line_len < MAX_LINE) {
            line_buffer[line_len] = char;
            line_len += 1;
            cursor_pos += 1;
        }
    }
    redrawLine();
}
