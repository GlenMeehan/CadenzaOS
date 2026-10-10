// src/kernel/config.zig
//
// Centralised kernel configuration.
//
// This file collects compile-time constants and global runtime
// references shared across the kernel.
//
// Responsibilities:
//   - Filesystem layout constants
//   - Buffer and terminal sizing
//   - Shell command identifiers
//   - System policy presets
//   - Scheduler and timer configuration
//   - Runtime kernel globals
//   - Versioning and build metadata
//
// Keeping these values in a single location makes tuning,
// experimentation, and system-wide changes easier during
// kernel development.

const std = @import("std");
const CodaFs = @import("fs/coda_fs.zig").CodaFs;
const builtin = @import("builtin");
const ver = @import("version.zig");

// ============================================================
// Filesystem & Disk Layout
// ============================================================

/// First sector of the filesystem partition.
///
/// 4096-sector alignment leaves room for bootloader data, staging
/// regions, and future disk metadata ahead of the filesystem.
pub const PARTITION_START_LBA: u64 = 4096;

/// Raw staging area for the embedded prog1 image (read by installEmbeddedApps,
/// written by build.sh). Must sit after the kernel image and before the partition.
pub const APP_LBA_START: u64 = 3700;
pub const APP_MAX_SECTORS: u64 = 48;

comptime {
    if (APP_LBA_START + APP_MAX_SECTORS > PARTITION_START_LBA)
        @compileError("app staging area overlaps the CodaFS partition");
}

/// Logical block address of the filesystem superblock.
///
/// This is relative to the start of the filesystem partition, not
/// the physical disk.
pub const SB_LBA: u64 = 0;

/// Filesystem block size in bytes.
///
/// Currently matches the underlying ATA sector size.
pub const BLOCK_SIZE: u64 = 512;

/// Total virtual disk capacity in sectors.
///
/// 20,480 sectors × 512 bytes = 10 MiB.
pub const DISK_SECTOR_COUNT: u64 = 20480;


// ============================================================
// Buffer Sizes
// ============================================================

/// Base I/O buffer size used throughout the kernel.
pub const BASE_IO_BUF_SIZE = BLOCK_SIZE;

/// Keyboard input ring-buffer capacity.
///
/// Large enough to absorb short bursts of typing without
/// immediately overflowing.
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
/// Stored as u8 values to keep command dispatch and behavioural
/// tracking tables lightweight.
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
/// Policies can influence shell behaviour, prompts,
/// persistence decisions, scheduling preferences,
/// and safety-related checks.
pub const SystemPolicy = enum(u8) {

    /// Development-oriented profile with minimal friction.
    DEV,

    /// Performance-oriented profile with reduced safety checks.
    GAMING,

    /// Conservative profile prioritising validation and stability.
    ADMIN,
};

/// Active runtime policy.
///
/// This may eventually be controlled through configuration files,
/// boot parameters, or persistent system settings.
pub var current_policy: SystemPolicy = .ADMIN;


// ============================================================
// Scheduler Configuration
// ============================================================

/// Cooperative/preemptive scheduler tuning values.
pub const scheduler = struct {

    /// Number of timer ticks a task receives before a
    /// scheduler-driven context switch occurs.
    ///
    /// Lower values:
    ///   - Better responsiveness
    ///   - More interactive feel
    ///
    /// Higher values:
    ///   - Lower scheduling overhead
    ///   - Better throughput for long-running work
    pub const timeslice_ticks: u32 = 10;

    /// Maximum number of concurrently scheduled tasks.
    pub const max_tasks: usize = 8;

    /// Default stack size assigned to newly created tasks.
    ///
    /// 4 KiB is sufficient for the current kernel workload but
    /// may need adjustment as task complexity increases.
    pub const default_stack_size: usize = 4096;
};


// ============================================================
// Timer Configuration
// ============================================================

pub const timer = struct {

    /// System timer frequency.
    ///
    /// 100 Hz corresponds to a 10 ms tick interval.
    pub const frequency_hz: u32 = 100;

    /// Select the interrupt controller and timer source used
    /// for periodic system ticks.
    ///
    /// false: Legacy PIC/PIT configuration.
    /// true : Local APIC timer configuration.
    pub var use_apic: bool = false;
};


/// Enable shell execution through the scheduler.
///
/// When disabled, shell commands may execute directly without
/// task scheduling overhead.
pub const USE_SCHEDULER_SHELL = true;


// ============================================================
// Runtime Kernel Globals
// ============================================================

/// Global filesystem instance.
///
/// Initialised during early kernel startup and used throughout
/// the filesystem layer.
pub var fs_global: *CodaFs = undefined;

/// Global kernel allocator.
///
/// Must be initialised before any dynamic memory allocation
/// is performed.
pub var kernel_allocator: std.mem.Allocator = undefined;

// ============================================================
// Versioning
// ============================================================

/// Kernel semantic version information.
pub const Version = struct {
    pub const major: u32 = 0;
    pub const minor: u32 = 4;
    pub const patch: u32 = 5;  //1. Continued clean up of comments bitmap.zig - kernel.zig completed 2. Kernel setup VGAessageing setup so splash screen is tidy.
};

/// Build metadata generated at build time.
pub const build = struct {
    pub const git_hash: []const u8 = ver.git_hash;
    pub const git_dirty: bool = ver.git_dirty;
    pub const timestamp: []const u8 = ver.build_ts;
};
