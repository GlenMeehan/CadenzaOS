// src/kernel/conductor.zig

const std = @import("std");
const vitals = @import("vitals.zig");
const vga = @import("vga.zig");
const coda = @import("fs/coda_fs.zig");
const conf = @import("config.zig");


//The Composer
// A Markov transition table
// Dynamically size the table based on the IDs in config
const cmd_count = std.enums.values(conf.CommandID).len;

// 10x10+ table is plenty of room to grow
pub var transition_table: [cmd_count][cmd_count]u16 = .{.{0} ** cmd_count} ** cmd_count;

/// The Conductor's assessment of system harmony.
pub const ConductorState = enum {
    Optimal,    // Low latency, full features
    Discordant, // High latency, defer disk updates
    Critical,   // Emergency latency, lock I/O
};

pub var current_state: ConductorState = .Optimal;



// Thresholds in CPU cycles.
// Note: These are 'magic numbers' you'll tune as your OS grows.
const DISCORDANCE_THRESHOLD: u64 = 10_000_000;
const CRITICAL_THRESHOLD: u64 = 50_000_000;

// A pointer to the live policy sitting in the filesystem superblock
var policy_ptr: ?*coda.SystemPolicy = null;

/// Links the Conductor to the actual System Policy
pub fn init(ptr: *coda.SystemPolicy) void {
    policy_ptr = ptr;
}

/// Analyzes current telemetry and updates the System State.
/// This is the "Pulse Check" for Cadenza OS.
pub fn evaluateTempo() void {
    const latency = vitals.current_vitals.last_read_latency;

    if (latency > CRITICAL_THRESHOLD) {
        if (current_state != .Critical) {
            current_state = .Critical;

            // ACT: If we have the pointer, force the policy to Admin
            if (policy_ptr) |p| {
                p.* = .Admin;
            }

            vga.writeString("\n!! CONDUCTOR: CRITICAL - FORCING ADMIN POLICY !!\n", 12, 0);
        }
    } else if (latency > DISCORDANCE_THRESHOLD) {
        if (current_state != .Discordant) {
            current_state = .Discordant;
            // Yellow alert: disk is slow, stop optional writes
            vga.writeString("\n!! CONDUCTOR: DEFERRING BRAIN SYNC !!\n", 14, 0);
        }
    } else {
        if (current_state != .Optimal) {
            current_state = .Optimal;
            // Green: system is back in rhythm
            vga.writeString("\n!! CONDUCTOR: TEMPO RESTORED !!\n", 10, 0);
        }
    }
}

/// Returns true if the system is healthy enough to perform disk-intensive AI saves.
pub fn canSave() bool {
    // Only 'Optimal' allows the Composer to hit the disk.
    return current_state == .Optimal;
}


/// The pulse of the Conductor (the metronome). This should be called
/// frequently to monitor system health.
pub fn tick() void {
    // 1. Tell vitals to refresh the hardware counters
    vitals.update();

    // 2. Run the evaluation logic
    evaluateTempo();
}
