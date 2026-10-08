// src/kernel/input/keyboard.zig
//
// PS/2 keyboard handler (Set 1 scancodes).
//
// Converts raw keyboard scancodes into higher-level input events
// (ASCII characters or special keys).
//
// Handles:
//   • Shift / Ctrl / Alt modifiers
//   • Extended (E0-prefixed) keys
//   • Ctrl-letter combinations
//   • Navigation keys (arrows, Home, End, Delete)
//
// NOTE:
//
//   The keyboard generates separate press and release events:
//
//       Make  = key pressed
//       Break = key released
//
//   For Set 1 scancodes:
//       Break = Make | 0x80
//
//   Extended keys begin with the 0xE0 prefix and may also involve
//   additional release prefixes depending on the device. Prefix
//   state is tracked explicitly during scancode decoding.

const std = @import("std");
const config = @import("../config.zig");
const root = @import("../kernel.zig");
const term = root.term;

// -----------------------------------------------------------------------------
// ASCII keymaps (Set 1 scancodes -> ASCII)
// -----------------------------------------------------------------------------
//
// These tables provide direct translation from Set 1 keyboard scancodes
// to printable ASCII characters.
//
// KEYMAP         -> unmodified keys
// KEYMAP_SHIFTED -> keys while Shift is active
//
// Entries that do not produce printable characters are left as null.

pub const KEYMAP: [128]?u8 = blk: {
    var map: [128]?u8 = .{null} ** 128;

    // Letters (US QWERTY)
    map[0x1E] = 'a'; map[0x30] = 'b'; map[0x2E] = 'c';
    map[0x20] = 'd'; map[0x12] = 'e'; map[0x21] = 'f';
    map[0x22] = 'g'; map[0x23] = 'h'; map[0x17] = 'i';
    map[0x24] = 'j'; map[0x25] = 'k'; map[0x26] = 'l';
    map[0x32] = 'm'; map[0x31] = 'n'; map[0x18] = 'o';
    map[0x19] = 'p'; map[0x10] = 'q'; map[0x13] = 'r';
    map[0x1F] = 's'; map[0x14] = 't'; map[0x16] = 'u';
    map[0x2F] = 'v'; map[0x11] = 'w'; map[0x2D] = 'x';
    map[0x15] = 'y'; map[0x2C] = 'z';

    // Number row
    map[0x0B] = '0'; map[0x02] = '1'; map[0x03] = '2';
    map[0x04] = '3'; map[0x05] = '4'; map[0x06] = '5';
    map[0x07] = '6'; map[0x08] = '7'; map[0x09] = '8';
    map[0x0A] = '9';

    // Whitespace and control characters
    map[0x39] = ' ';     // Space
    map[0x1C] = '\n';    // Enter
    map[0x0E] = '\x08';  // Backspace

    // Symbols
    map[0x0C] = '-'; map[0x0D] = '=';
    map[0x1A] = '['; map[0x1B] = ']';
    map[0x27] = ';'; map[0x28] = '\'';
    map[0x29] = '`'; map[0x33] = ',';
    map[0x34] = '.'; map[0x35] = '/';

    break :blk map;
};

/// Shift-modified version of KEYMAP.
///
/// Produces uppercase letters and the shifted variants of symbol keys
/// according to the US QWERTY keyboard layout.
pub const KEYMAP_SHIFTED: [128]?u8 = blk: {
    var map: [128]?u8 = .{null} ** 128;

    // Uppercase letters
    map[0x1E] = 'A'; map[0x30] = 'B'; map[0x2E] = 'C';
    map[0x20] = 'D'; map[0x12] = 'E'; map[0x21] = 'F';
    map[0x22] = 'G'; map[0x23] = 'H'; map[0x17] = 'I';
    map[0x24] = 'J'; map[0x25] = 'K'; map[0x26] = 'L';
    map[0x32] = 'M'; map[0x31] = 'N'; map[0x18] = 'O';
    map[0x19] = 'P'; map[0x10] = 'Q'; map[0x13] = 'R';
    map[0x1F] = 'S'; map[0x14] = 'T'; map[0x16] = 'U';
    map[0x2F] = 'V'; map[0x11] = 'W'; map[0x2D] = 'X';
    map[0x15] = 'Y'; map[0x2C] = 'Z';

    // Shifted number row
    map[0x02] = '!'; map[0x03] = '@'; map[0x04] = '#';
    map[0x05] = '$'; map[0x06] = '%'; map[0x07] = '^';
    map[0x08] = '&'; map[0x09] = '*'; map[0x0A] = '(';
    map[0x0B] = ')';

    // Whitespace and control characters
    map[0x39] = ' ';
    map[0x1C] = '\n';
    map[0x0E] = '\x08';

    // Shifted symbols
    map[0x0C] = '_'; map[0x0D] = '+';
    map[0x1A] = '{'; map[0x1B] = '}';
    map[0x27] = ':'; map[0x28] = '"';
    map[0x29] = '~'; map[0x33] = '<';
    map[0x34] = '>'; map[0x35] = '?';

    break :blk map;
};

// -----------------------------------------------------------------------------
// Keyboard state
// -----------------------------------------------------------------------------
//
// Modifier state is tracked globally so incoming scancodes can be
// interpreted in the context of currently held keys.

var shift_down = false;
var ctrl_down = false;
var alt_down = false;

// Extended key tracking.
//
// 0xE0 indicates that the next scancode belongs to an extended key.
// Some keyboards may also emit 0xF0 as part of release sequences.
//
// These flags allow multi-byte scancode sequences to be decoded
// correctly across successive interrupts.
var extended = false;
var extended_release = false;

// -----------------------------------------------------------------------------
// Main entry point for PS/2 scancodes
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// Circular Input Queue (Ring Buffer)
// -----------------------------------------------------------------------------
//
// Bridges the interrupt handler and higher-level consumers.
//
// The keyboard ISR pushes characters into the queue while tasks pull
// them out asynchronously. Atomic head/tail indices provide simple
// single-producer/single-consumer synchronisation.

const BUFFER_SIZE = 64;

pub const RingBuffer = struct {
    data: [BUFFER_SIZE]u8 = [_]u8{0} ** BUFFER_SIZE,
    head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Attempt to append a character to the queue.
    ///
    /// Returns false if the buffer is full.
    pub fn push(self: *RingBuffer, ch: u8) bool {
        const current_head = self.head.load(.monotonic);
        const current_tail = self.tail.load(.acquire);

        const next_head = (current_head + 1) % BUFFER_SIZE;

        if (next_head == current_tail) {
            return false; // Buffer full
        }

        self.data[current_head] = ch;

        // Release ordering guarantees the character write is visible
        // before the updated head index becomes observable.
        self.head.store(next_head, .release);

        return true;
    }

    /// Remove and return the next queued character.
    ///
    /// Returns null if the queue is empty.
    pub fn pop(self: *RingBuffer) ?u8 {
        const current_tail = self.tail.load(.monotonic);

        // Acquire ordering ensures visibility of writes performed
        // before the producer advanced head.
        const current_head = self.head.load(.acquire);

        if (current_head == current_tail) {
            return null; // Buffer empty
        }

        const ch = self.data[current_tail];
        const next_tail = (current_tail + 1) % BUFFER_SIZE;

        // Release ordering safely publishes the new tail position.
        self.tail.store(next_tail, .release);

        return ch;
    }
};

// Global queue used to transfer keyboard input from interrupt context
// to normal kernel code.
pub var input_queue = RingBuffer{};

/// Retrieve the next available character from the keyboard queue.
///
/// Returns null if no input is currently available.
pub fn readChar() ?u8 {
    return input_queue.pop();
}

/// Most recently generated character.
///
/// Retained for compatibility with older code paths that still access
/// keyboard state directly rather than using the input queue.
pub var last_char: u8 = 0;

/// Process a single keyboard scancode.
///
/// Converts raw PS/2 input into either queued ASCII characters or
/// higher-level special-key events.
pub fn handleScancode(scancode: u8) void {

    // Start of an extended-key sequence.
    if (scancode == 0xE0) {
        extended = true;
        return;
    }

    // Release prefix observed in some extended-key sequences.
    if (extended and scancode == 0xF0) {
        extended_release = true;
        return;
    }

    // Extended keys are decoded separately from the standard keymap.
    if (extended) {
        handleExtended(scancode);
        extended = false;
        extended_release = false;
        return;
    }

    // Non-ASCII special keys handled directly.
    switch (scancode) {
        0x01 => { term.handleKeyEvent(.{ .special = .Escape }); return; },
        0x0F => { term.handleKeyEvent(.{ .special = .Tab }); return; },
        else => {},
    }

    updateModifiers(scancode);

    // Translate printable keys through the active keymap.
    if (scancodeToAscii(scancode)) |ch| {
        const final_ch = if (ctrl_down)
        (ch & 0x1F) // Convert Ctrl+A..Ctrl+Z into control characters
        else
            ch;

        // Preserve legacy access pattern.
        last_char = final_ch;

        // Queue the character for later consumption outside
        // interrupt context.
        _ = input_queue.push(final_ch);

        // Character delivery via KeyEvent has intentionally been moved
        // out of interrupt context to avoid UI work inside the ISR.
        // term.handleKeyEvent(.{ .char = final_ch });

        if (ctrl_down) return;
    }
}

// -----------------------------------------------------------------------------
// ASCII conversion
// -----------------------------------------------------------------------------

/// Convert a Set 1 make-code into an ASCII character.
///
/// Returns null for:
///   • key releases
///   • unmapped scancodes
///   • non-printable keys
fn scancodeToAscii(sc: u8) ?u8 {
    if (sc & 0x80 != 0) return null; // Ignore break codes
    if (sc >= KEYMAP.len) return null;

    return if (shift_down)
    KEYMAP_SHIFTED[sc]
    else
        KEYMAP[sc];
}

// -----------------------------------------------------------------------------
// Modifier keys (Shift, Ctrl, Alt)
// -----------------------------------------------------------------------------

/// Update modifier key state from a make or break scancode.
fn updateModifiers(sc: u8) void {
    const is_release = (sc & 0x80) != 0;
    const code = sc & 0x7F;

    if (code == 0x2A or code == 0x36) {
        shift_down = !is_release;
        return;
    }

    if (code == 0x1D) {
        ctrl_down = !is_release;
        return;
    }

    if (code == 0x38) {
        alt_down = !is_release;
        return;
    }
}

// -----------------------------------------------------------------------------
// Extended keys (E0-prefixed)
// -----------------------------------------------------------------------------

/// Handle decoded E0-prefixed keys.
///
/// Supports both Set 1 and Set 2 variants for common navigation keys.
fn handleExtended(sc: u8) void {
    const is_release = (sc & 0x80) != 0;

    if (is_release) return;

    const code = sc & 0x7F;

    switch (code) {
        0x48, 0x75 => term.handleKeyEvent(.{ .special = .Up }),
        0x50, 0x72 => term.handleKeyEvent(.{ .special = .Down }),
        0x4B, 0x6B => term.handleKeyEvent(.{ .special = .Left }),
        0x4D, 0x74 => term.handleKeyEvent(.{ .special = .Right }),
        0x53       => term.handleKeyEvent(.{ .special = .Delete }),
        0x47       => term.handleKeyEvent(.{ .special = .Home }),
        0x4F       => term.handleKeyEvent(.{ .special = .End }),
        else => {},
    }
}
