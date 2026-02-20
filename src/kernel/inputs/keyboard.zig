// src/kernel/input/keyboard.zig
const config = @import("../config.zig");

pub const KEYMAP: [128]?u8 = blk: {
    var map: [128]?u8 = .{null} ** 128;

    // Letters (US QWERTY)
    map[0x1E] = 'a';
    map[0x30] = 'b';
    map[0x2E] = 'c';
    map[0x20] = 'd';
    map[0x12] = 'e';
    map[0x21] = 'f';
    map[0x22] = 'g';
    map[0x23] = 'h';
    map[0x17] = 'i';
    map[0x24] = 'j';
    map[0x25] = 'k';
    map[0x26] = 'l';
    map[0x32] = 'm';
    map[0x31] = 'n';
    map[0x18] = 'o';
    map[0x19] = 'p';
    map[0x10] = 'q';
    map[0x13] = 'r';
    map[0x1F] = 's';
    map[0x14] = 't';
    map[0x16] = 'u';
    map[0x2F] = 'v';
    map[0x11] = 'w';
    map[0x2D] = 'x';
    map[0x15] = 'y';
    map[0x2C] = 'z';

    // Numbers
    map[0x0B] = '0';
    map[0x02] = '1';
    map[0x03] = '2';
    map[0x04] = '3';
    map[0x05] = '4';
    map[0x06] = '5';
    map[0x07] = '6';
    map[0x08] = '7';
    map[0x09] = '8';
    map[0x0A] = '9';

    // Space
    map[0x39] = ' ';

    // Enter
    map[0x1C] = '\n';

    // Backspace
    map[0x0E] = '\x08';

    map[0x0C] = '-';
    map[0x0D] = '=';
    map[0x1A] = '[';
    map[0x1B] = ']';
    map[0x27] = ';';
    map[0x28] = '\'';
    map[0x29] = '`';
    map[0x33] = ',';
    map[0x34] = '.';
    map[0x35] = '/';

    //map[0x0F] = '\t';
    //map[0x01] = 0x1B;


    break :blk map;
};

pub const KEYMAP_SHIFTED: [128]?u8 = blk: {
    var map: [128]?u8 = .{null} ** 128;

    // Letters (US QWERTY) – uppercase
    map[0x1E] = 'A';
    map[0x30] = 'B';
    map[0x2E] = 'C';
    map[0x20] = 'D';
    map[0x12] = 'E';
    map[0x21] = 'F';
    map[0x22] = 'G';
    map[0x23] = 'H';
    map[0x17] = 'I';
    map[0x24] = 'J';
    map[0x25] = 'K';
    map[0x26] = 'L';
    map[0x32] = 'M';
    map[0x31] = 'N';
    map[0x18] = 'O';
    map[0x19] = 'P';
    map[0x10] = 'Q';
    map[0x13] = 'R';
    map[0x1F] = 'S';
    map[0x14] = 'T';
    map[0x16] = 'U';
    map[0x2F] = 'V';
    map[0x11] = 'W';
    map[0x2D] = 'X';
    map[0x15] = 'Y';
    map[0x2C] = 'Z';

    // Numbers row with symbols
    map[0x02] = '!'; // 1
    map[0x03] = '@'; // 2
    map[0x04] = '#'; // 3
    map[0x05] = '$'; // 4
    map[0x06] = '%'; // 5
    map[0x07] = '^'; // 6
    map[0x08] = '&'; // 7
    map[0x09] = '*'; // 8
    map[0x0A] = '('; // 9
    map[0x0B] = ')'; // 0

    // Space, Enter, Backspace same as unshifted
    map[0x39] = ' ';
    map[0x1C] = '\n';
    map[0x0E] = '\x08';

    map[0x0C] = '_';
    map[0x0D] = '+';
    map[0x1A] = '{';
    map[0x1B] = '}';
    map[0x27] = ':';
    map[0x28] = '"';
    map[0x29] = '~';
    map[0x33] = '<';
    map[0x34] = '>';
    map[0x35] = '?';
    map[0x0C] = '_';
    map[0x0D] = '+';
    map[0x1A] = '{';
    map[0x1B] = '}';
    map[0x27] = ':';
    map[0x28] = '"';
    map[0x29] = '~';
    map[0x33] = '<';
    map[0x34] = '>';
    map[0x35] = '?';


    break :blk map;
};


const vga = @import("../vga.zig");
const conv = @import("../convert.zig");
//const term = @import("../terminal.zig");
const root = @import("../kernel.zig");
const term = root.term;

pub fn handleScancode(scancode: u8) void {

    // Extended prefix
    if (scancode == 0xE0) {
        extended = true;
        return;
    }

    // Extended release prefix (Set 2)
    if (extended and scancode == 0xF0) {
        extended_release = true;
        return;
    }

    // If we're in an extended sequence, handle it there
    if (extended) {
        handleExtended(scancode);
        extended = false;
        extended_release = false;
        return;
    }

    // Handle special keys BEFORE ASCII mapping
    switch (scancode) {
        0x01 => { term.handleKeyEvent(.{ .special = .Escape }); return; }, // ESC
        0x0F => { term.handleKeyEvent(.{ .special = .Tab }); return; },    // Tab
        else => {},
    }

    updateModifiers(scancode);

    // ASCII mapping
    if (scancodeToAscii(scancode)) |ch| {

        // CTRL combinations (Ctrl-A → 0x01, Ctrl-E → 0x05, etc.)
        if (ctrl_down) {
            const ctrl_code = ch & 0x1F;
            term.handleKeyEvent(.{ .char = ctrl_code });
            return;
        }

        // Normal ASCII character
        term.handleKeyEvent(.{ .char = ch });
    }
}



fn scancodeToAscii(sc: u8) ?u8 {
    if (sc & 0x80 != 0) return null; // ignore releases for now
    if (sc >= KEYMAP.len) return null;

    if (shift_down) {
        return KEYMAP_SHIFTED[sc];
    } else {
        return KEYMAP[sc];
    }
}


const BUF_SIZE = config.KEYBOARD_BUF_SIZE;
var buf: [BUF_SIZE]u8 = undefined;
var head: usize = 0;
var tail: usize = 0;

var shift_down: bool = false;
var ctrl_down: bool = false;
var alt_down: bool = false;
var extended: bool = false;
var extended_release: bool = false;

fn push(c: u8) void {
    const next = (head + 1) % BUF_SIZE;
    if (next == tail) {
        // buffer full, drop character
        return;
    }
    buf[head] = c;
    head = next;
}

pub fn pop() ?u8 {
    if (head == tail) return null;
    const c = buf[tail];
    tail = (tail + 1) % BUF_SIZE;
    return c;
}

fn updateModifiers(sc: u8) void {
    const is_release = (sc & 0x80) != 0;
    const code = sc & 0x7F;

    // Shift
    if (code == 0x2A or code == 0x36) {
        shift_down = !is_release;
        return;
    }

    // Ctrl
    if (code == 0x1D) {
        ctrl_down = !is_release;
        return;
    }

    // Alt
    if (code == 0x38) {
        alt_down = !is_release;
        return;
    }
}

fn handleExtended(sc: u8) void {
    const is_release = (sc & 0x80) != 0;
    const code = sc & 0x7F;

    if (is_release) {
        // Ignore releases for now
        return;
    }

    switch (code) {
        0x48, 0x75 => term.handleKeyEvent(.{ .special = .Up }),
        0x50, 0x72 => term.handleKeyEvent(.{ .special = .Down }),
        0x4B, 0x6B => term.handleKeyEvent(.{ .special = .Left }),
        0x4D, 0x74 => term.handleKeyEvent(.{ .special = .Right }),
        0x53 => term.handleKeyEvent(.{ .special = .Delete }),
        0x47 => term.handleKeyEvent(.{.special = . Home}),
        0x4F => term.handleKeyEvent(.{.special = . End}),
        else => {},
    }
}


