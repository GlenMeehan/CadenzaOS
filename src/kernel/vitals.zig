// src/kernel/vitals.zig
//
// Tracks lightweight runtime metrics for the kernel.
// These values are updated by subsystems such as the disk driver
// and early boot code. They are intentionally minimal so they can
// be read or written without heavy synchronisation.
//
// NOTE:
//  - No logic here; this module only defines the structure and
//    the global instance.
//  - All fields are monotonic counters or timestamps.
//  - Extend carefully: this struct is often read in hot paths.

pub const Vitals = struct {
    /// Total number of disk I/O cycles performed since boot.
    disk_cycles: u64 = 0,

    /// Timestamp captured during early boot (units depend on your timer source).
    boot_timestamp: u64 = 0,

    /// Latency of the most recent disk read operation (in cycles or microseconds).
    last_read_latency: u64 = 0,
};

/// Global instance of kernel vitals.
/// Subsystems update this directly.
pub var current_vitals = Vitals{};
