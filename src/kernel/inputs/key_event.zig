// src/kernel/input/key_event.zig

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
