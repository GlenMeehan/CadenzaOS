// src/kernel/config.zig
//
// Centralized kernel configuration constants.
// These values control buffer sizes and argument limits
// for various subsystems (keyboard, terminal, shell, etc.).

pub const PARTITION_START_LBA: u64 = 2048;
pub const SB_LBA: u64 = 2048; // Superblock location
pub const BLOCK_SIZE: u64 = 512; // Standard Block Size
pub const DISK_SECTOR_COUNT: u64 = 20480; // 10 MiB total capacity

pub const BASE_IO_BUF_SIZE     = BLOCK_SIZE;
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
    SHUTDOWN = 10,
    REBOOT = 11,
    DEL = 12,
    RENAME  = 13,
    MOVE    = 14,
    VERSION = 15,
    UPTIME = 16,
    DF = 17,
};


pub const SystemPolicy = enum(u8) {
    DEV,      // High speed, low prompts (for you to build).
    GAMING,   // Performance focus, stability rails off.
    ADMIN,    // High stability, strict habit checking.
};

// Default policy - you can change this to simulate the "Setup" choice
pub var current_policy: SystemPolicy = .DEV;
