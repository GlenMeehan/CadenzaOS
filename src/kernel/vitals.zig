// src/kernel/vitals.zig
//
// Lightweight kernel runtime telemetry.
//
// This module exposes a small collection of system-health and
// performance metrics that can be updated by multiple subsystems.
//
// Design goals:
//   • Low overhead
//   • Simple direct access
//   • Minimal synchronisation requirements
//   • Suitable for early-boot and runtime diagnostics
//
// Note:
//   • This module stores metrics only.
//   • It does not perform analysis or policy decisions.
//   • New fields should remain inexpensive to update and read.
//
pub const Vitals = struct {

    /// Total number of disk I/O operations performed since boot.
    disk_cycles: u64 = 0,

    /// Timestamp captured during kernel startup.
    ///
    /// Units depend on the active timing source.
    boot_timestamp: u64 = 0,

    /// Duration of the most recent disk read operation.
    ///
    /// Units depend on the subsystem providing the measurement.
    last_read_latency: u64 = 0,

    /// Most recently sampled processor time-stamp counter value.
    total_cycles: u64 = 0,
};

/// Global kernel telemetry state.
///
/// Subsystems update these counters directly as activity occurs.
pub var current_vitals = Vitals{
    .last_read_latency = 0,
    .total_cycles = 0,
};

/// Refresh processor timing information.
///
/// Reads the current Time Stamp Counter (TSC) using the x86_64
/// RDTSC instruction and stores the resulting cycle count in
/// current_vitals.total_cycles.
pub fn update() void {
    var low: u32 = undefined;
    var high: u32 = undefined;

    // Read the processor Time Stamp Counter.
    asm volatile ("rdtsc"
    : [low] "={ax}" (low),
                  [high] "={dx}" (high),
    );

    current_vitals.total_cycles =
    (@as(u64, high) << 32) | low;

    // ---------------------------------------------------------------------
    //  DIAGNOSTIC TEST VALUE
    // ---------------------------------------------------------------------
    //
    // Useful when testing telemetry consumers that respond to high
    // latency conditions.
    //
    // current_vitals.last_read_latency = 60_000_000;
}
