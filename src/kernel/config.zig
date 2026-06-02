// src/kernel/config.zig
//
// Centralized kernel configuration.
//
// This file contains compile-time constants and global runtime
// references shared across the kernel.
//
// Responsibilities:
//   - Filesystem layout constants
//   - Buffer and terminal sizing
//   - Shell command identifiers
//   - System policy presets
//   - Scheduler/timer configuration
//   -  Runtime Kernel Globals
//
// Keeping these values here makes tuning and experimentation
// easier during kernel development.

const std = @import("std");
const CodaFs = @import("fs/coda_fs.zig").CodaFs;


// ============================================================
// Filesystem & Disk Layout
// ============================================================

/// First usable partition sector.
///
/// 2048 is commonly used for alignment on modern disks.
pub const PARTITION_START_LBA: u64 = 2048;

/// Logical block address of the filesystem superblock.
pub const SB_LBA: u64 = PARTITION_START_LBA;

/// Filesystem block size in bytes.
///
/// Currently aligned to a standard disk sector.
pub const BLOCK_SIZE: u64 = 512;

/// Total virtual disk capacity in sectors.
///
/// 20480 sectors × 512 bytes = 10 MiB.
pub const DISK_SECTOR_COUNT: u64 = 20480;


// ============================================================
// Buffer Sizes
// ============================================================

/// Base I/O buffer size used throughout the kernel.
pub const BASE_IO_BUF_SIZE = BLOCK_SIZE;

/// Keyboard input ring buffer size.
///
/// Large enough to comfortably absorb burst typing.
pub const KEYBOARD_BUF_SIZE = BASE_IO_BUF_SIZE * 8;

/// Maximum terminal input line length.
pub const TERMINAL_LINE_SIZE = BASE_IO_BUF_SIZE * 8;

/// Maximum number of parsed shell arguments.
pub const MAX_ARGS: usize = 16;


// ============================================================
// Shell Command Identifiers
// ============================================================

/// Compact command identifiers used by the shell parser.
///
/// Stored as u8 to keep command dispatch lightweight.
pub const CommandID = enum(u8) {
    UNKNOWN = 0,

    // Filesystem commands
    LS       = 1,
    CD       = 2,
    MKDIR    = 3,
    STAT     = 4,
    CAT      = 5,
    TOUCH    = 7,
    DEL      = 12,
    RENAME   = 13,
    MOVE     = 14,

    // System / policy commands
    POLICY   = 6,
    VITALS   = 9,
    SHUTDOWN = 10,
    REBOOT   = 11,
    VERSION  = 15,
    UPTIME   = 16,
    DF       = 17,

    // Process / task commands
    EDIT     = 8,
    SPAWN    = 18,
};


// ============================================================
// System Policies
// ============================================================

/// Kernel operating policy presets.
///
/// These can influence shell behaviour, prompts,
/// scheduling aggressiveness, safety checks, etc.
pub const SystemPolicy = enum(u8) {
    /// High speed, minimal prompts.
    DEV,

    /// Performance-focused with reduced safety rails.
    GAMING,

    /// Stability and validation focused.
    ADMIN,
};

/// Active runtime policy.
///
/// This can later be made configurable via setup,
/// boot arguments, or persisted configuration.
pub var current_policy: SystemPolicy = .ADMIN;


// ============================================================
// Scheduler Configuration
// ============================================================

/// Cooperative/preemptive scheduler tuning values.
pub const scheduler = struct {

    /// Number of timer ticks a task receives
    /// before a forced context switch occurs.
    ///
    /// Lower values:
    ///   - Better responsiveness
    ///   - More "parallel" feel
    ///
    /// Higher values:
    ///   - Lower scheduling overhead
    ///   - Better raw throughput
    pub const timeslice_ticks: u32 = 10;

    /// Maximum simultaneous tasks supported.
    pub const max_tasks: usize = 8;

    /// Default stack size allocated for new tasks.
    ///
    /// 4 KiB is a typical baseline stack size.
    pub const default_stack_size: usize = 4096;
};


// ============================================================
// Timer Configuration
// ============================================================

pub const timer = struct {

    /// Programmable Interval Timer (PIT) frequency.
    ///
    /// 100 Hz = 10 ms timer interval.
    pub const frequency_hz: u32 = 100;
};


/// Enables shell execution through the scheduler.
///
/// When false, shell commands may execute directly
/// without task scheduling.
pub const USE_SCHEDULER_SHELL = true;


// ============================================================
// Runtime Kernel Globals
// ============================================================

/// Global filesystem instance.
///
/// Initialized during early kernel boot.
pub var fs_global: *CodaFs = undefined;

/// Global kernel allocator.
///
/// Must be initialized before dynamic allocation.
pub var kernel_allocator: std.mem.Allocator = undefined;


