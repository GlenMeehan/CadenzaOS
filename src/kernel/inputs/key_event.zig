// src/kernel/input/key_event.zig
//
// Represents a keyboard event delivered by the input subsystem.
// A key event is either:
//   • a printable ASCII character (char)
//   • a non‑printable special key (special)

pub const KeyEvent = union(enum) {
    char: u8,
    special: SpecialKey,
};

pub const SpecialKey = enum {
    Left,
    Right,
    Up,
    Down,
    Home,
    End,
    Escape,
    Tab,
    Delete,
};
