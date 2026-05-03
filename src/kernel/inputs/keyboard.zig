// src/kernel/input/keyboard.zig
//
// PS/2 keyboard handler (Set 1 scancodes).
// Converts raw scancodes → KeyEvent (ascii or special).
// Handles:
//   • Shift / Ctrl / Alt modifiers
//   • Extended keys (E0-prefixed)
//   • Ctrl-letter combinations
//   • Arrow keys, Home/End, Delete
//
// NOTE:
//   The keyboard hardware sends *make* (press) and *break* (release) codes.
//   Make = scancode
//   Break = scancode | 0x80
//
//   Extended keys begin with 0xE0 and sometimes 0xF0 (Set 2 release).
//   We track these prefixes explicitly.

const config = @import("../config.zig");
const root = @import("../kernel.zig");
const term = root.term;

// -----------------------------------------------------------------------------
// ASCII keymaps (Set 1 scancodes → ASCII)
// -----------------------------------------------------------------------------

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

    // Numbers row
    map[0x0B] = '0'; map[0x02] = '1'; map[0x03] = '2';
    map[0x04] = '3'; map[0x05] = '4'; map[0x06] = '5';
    map[0x07] = '6'; map[0x08] = '7'; map[0x09] = '8';
    map[0x0A] = '9';

    // Whitespace + control
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

    // Whitespace + control
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

var shift_down = false;
var ctrl_down = false;
var alt_down = false;

// Extended key tracking:
//   0xE0 = extended prefix
//   0xF0 = release prefix (Set 2)
// We track these so the next scancode is interpreted correctly.
var extended = false;
var extended_release = false;

// -----------------------------------------------------------------------------
// Main entry point for PS/2 scancodes
// -----------------------------------------------------------------------------

pub var last_char: u8 = 0;

pub fn handleScancode(scancode: u8) void {
    // 0xE0 = extended key prefix
    if (scancode == 0xE0) {
        extended = true;
        return;
    }

    // 0xF0 = release prefix (only appears after 0xE0 in Set 2)
    if (extended and scancode == 0xF0) {
        extended_release = true;
        return;
    }

    // If we are in an extended sequence, handle it separately
    if (extended) {
        handleExtended(scancode);
        extended = false;
        extended_release = false;
        return;
    }

    // Non‑ASCII special keys (ESC, Tab)
    switch (scancode) {
        0x01 => { term.handleKeyEvent(.{ .special = .Escape }); return; },
        0x0F => { term.handleKeyEvent(.{ .special = .Tab }); return; },
        else => {},
    }

    updateModifiers(scancode);

    // ASCII mapping
    if (scancodeToAscii(scancode)) |ch| {
        // 1. Determine the final character (handling Ctrl modification)
        const final_ch = if (ctrl_down) (ch & 0x1F) else ch;

        // 2. Update the "Memory" for the Confirmation Service
        last_char = final_ch;

        // 3. Update the "UI" (Terminal)
        term.handleKeyEvent(.{ .char = final_ch });

        // If it was a Ctrl combo, we return early as you did before
        if (ctrl_down) return;
    }
}

// -----------------------------------------------------------------------------
// ASCII conversion
// -----------------------------------------------------------------------------

fn scancodeToAscii(sc: u8) ?u8 {
    if (sc & 0x80 != 0) return null; // ignore releases
    if (sc >= KEYMAP.len) return null;

    return if (shift_down)
    KEYMAP_SHIFTED[sc]
    else
        KEYMAP[sc];
}

// -----------------------------------------------------------------------------
// Modifier keys (Shift, Ctrl, Alt)
// -----------------------------------------------------------------------------

fn updateModifiers(sc: u8) void {
    const is_release = (sc & 0x80) != 0;
    const code = sc & 0x7F;

    if (code == 0x2A or code == 0x36) { shift_down = !is_release; return; }
    if (code == 0x1D) { ctrl_down = !is_release; return; }
    if (code == 0x38) { alt_down = !is_release; return; }
}

// -----------------------------------------------------------------------------
// Extended keys (E0-prefixed)
// -----------------------------------------------------------------------------

fn handleExtended(sc: u8) void {
    const is_release = (sc & 0x80) != 0;
    if (is_release) return;

    const code = sc & 0x7F;

    // Supports both Set 1 and Set 2 codes
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
