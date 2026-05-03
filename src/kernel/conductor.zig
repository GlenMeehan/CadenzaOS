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
pub var transition_table = [_][32]u16{ [_]u16{0} ** 32 } ** 32;

/// The Conductor's assessment of system harmony.
pub const ConductorState = enum {
    Optimal,    // Low latency, full features
    Discordant, // High latency, defer disk updates
    Critical,   // Emergency latency, lock I/O
};

pub var current_state: ConductorState = .Optimal;

// Temporarily force the state to see the Shell respond
//pub var current_state = ConductorState.Discordant;

var decay_timer: u32 = 0;
const DECAY_INTERVAL: u32 = 100; // Decay every 100 'ticks'



// Thresholds in CPU cycles.
// Note: These are 'magic numbers' you'll tune as your OS grows.
const DISCORDANCE_THRESHOLD: u64 = 10_000_000;
const CRITICAL_THRESHOLD: u64 = 50_000_000;

// A pointer to the live policy sitting in the filesystem superblock
var policy_ptr: ?*coda.SystemPolicy = null;

/// Links the Conductor to the actual System Policy
pub fn init(ptr: *conf.SystemPolicy) void {
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
                p.* = .ADMIN;
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
            vga.writeString("\n!! CONDUCTOR: TEMPO RESTORED !!\n", 10, 0);
        }

        // Only age the brain when the system is healthy
        decay_timer += 1;
        if (decay_timer >= DECAY_INTERVAL) {
            decayHabits();
            decay_timer = 0;
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

/// Reduces the weight of all habits by ~10%.
/// Integer-based fixed-point math: (Value * 9) / 10.
pub fn decayHabits() void {
    for (&transition_table) |*row| {
        for (row) |*cell| {
            if (cell.* > 0) {
                // We cast to u32 to ensure the multiplication
                // doesn't overflow u16 before the division.
                const scaled: u32 = (@as(u32, cell.*) * 9) / 10;
                cell.* = @intCast(scaled);
            }
        }
    }
}

/// Returns the probability weight of a specific command sequence.
/// 0 means the user has never performed this sequence.
pub fn getScore(prev: conf.CommandID, curr: conf.CommandID) u16 {
    const p_idx = @intFromEnum(prev);
    const c_idx = @intFromEnum(curr);

    // Boundary check for safety
    if (p_idx >= transition_table.len or c_idx >= transition_table[0].len) return 0;

    return transition_table[p_idx][c_idx];
}


pub fn getTopScoreInRow(prev: conf.CommandID) u16 {
    const row = @intFromEnum(prev);
    if (row >= 16) return 0; // The safety fence

    var max_score: u16 = 0;
    for (0..16) |col| { // Only scan up to 15
        const score = transition_table[row][col];
        if (score > max_score) {
            max_score = score;
        }
    }
    return max_score;
}
