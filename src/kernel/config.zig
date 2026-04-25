// src/kernel/config.zig
//
// Centralized kernel configuration constants.
// These values control buffer sizes and argument limits
// for various subsystems (keyboard, terminal, shell, etc.).

pub const BASE_IO_BUF_SIZE     = 512;
pub const KEYBOARD_BUF_SIZE    = BASE_IO_BUF_SIZE * 8;
pub const TERMINAL_LINE_SIZE   = BASE_IO_BUF_SIZE * 8;

pub const MAX_ARGS             = 16;

//CommandID
pub const CommandID = enum(u8) {
    UNKNOWN = 0,
    LS      = 1,
    CD      = 2,
    MKDIR   = 3,
    STAT    = 4,
    CAT     = 5,
    POLICY  = 6,
    TOUCH   = 7,
    EDIT    = 8,
    VITALS  = 9,
    DEL     = 10,
    RENAME  = 11,
    MOVE    = 12,
    VERSION = 13,
};
