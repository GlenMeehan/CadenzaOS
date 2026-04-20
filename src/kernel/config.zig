// src/kernel/config.zig
//
// Centralized kernel configuration constants.
// These values control buffer sizes and argument limits
// for various subsystems (keyboard, terminal, shell, etc.).

pub const BASE_IO_BUF_SIZE     = 512;
pub const KEYBOARD_BUF_SIZE    = BASE_IO_BUF_SIZE * 8;
pub const TERMINAL_LINE_SIZE   = BASE_IO_BUF_SIZE * 8;

pub const MAX_ARGS             = 16;
