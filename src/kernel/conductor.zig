// src/kernel/conductor.zig

const std = @import("std");
const vitals = @import("vitals.zig");
const vga = @import("vga.zig");
const coda = @import("fs/coda_fs.zig");
const conf = @import("config.zig");

// The Conductor
//
// Maintains a simple behavioural model of command usage and monitors
// system health to determine whether background activity should be
// encouraged, deferred, or blocked.

// Markov-style transition table used to track command sequences.
//
// The active command set may be smaller, but the table is intentionally
// overprovisioned to allow future command growth without changing the
// on-disk learning model.
const cmd_count = std.enums.values(conf.CommandID).len;

// Fixed-size transition table storing transition weights between
// command pairs.
pub var transition_table = [_][32]u16{ [_]u16{0} ** 32 } ** 32;

/// The Conductor's assessment of overall system health.
pub const ConductorState = enum {
    Optimal,    // Low latency, all features enabled
    Discordant, // Elevated latency, defer non-essential work
    Critical,   // Severe latency, restrict expensive operations
};

pub var current_state: ConductorState = .Optimal;

// Useful during development for forcing alternative conductor states.
// pub var current_state = ConductorState.Discordant;

var decay_timer: u32 = 0;
const DECAY_INTERVAL: u32 = 100; // Habit decay period in scheduler ticks

// Latency thresholds measured in CPU cycles.
//
// These values are heuristic tuning parameters and may need adjustment
// as the kernel evolves.
const DISCORDANCE_THRESHOLD: u64 = 10_000_000;
const CRITICAL_THRESHOLD: u64 = 50_000_000;

// Pointer to the active system policy.
// Once initialised, the Conductor can influence system behaviour by
// updating this policy in response to changing conditions.
var policy_ptr: ?*coda.SystemPolicy = null;

/// Attach the Conductor to the live SystemPolicy instance.
pub fn init(ptr: *conf.SystemPolicy) void {
    policy_ptr = ptr;
}

/// Evaluate current telemetry and update the conductor state.
///
/// This acts as the system's "pulse check", allowing runtime policy
/// decisions to respond to measured latency.
pub fn evaluateTempo() void {
    const latency = vitals.current_vitals.last_read_latency;

    if (latency > CRITICAL_THRESHOLD) {
        if (current_state != .Critical) {
            current_state = .Critical;

            // Force the system into the most conservative policy mode.
            if (policy_ptr) |p| {
                p.* = .ADMIN;
            }

            vga.writeString(
                "\n!! CONDUCTOR: CRITICAL - FORCING ADMIN POLICY !!\n",
                12,
                0,
            );
        }
    } else if (latency > DISCORDANCE_THRESHOLD) {
        if (current_state != .Discordant) {
            current_state = .Discordant;

            // Disk latency is elevated. Defer optional persistence.
            vga.writeString(
                "\n!! CONDUCTOR: DEFERRING BRAIN SYNC !!\n",
                14,
                0,
            );
        }
    } else {
        if (current_state != .Optimal) {
            current_state = .Optimal;

            vga.writeString(
                "\n!! CONDUCTOR: TEMPO RESTORED !!\n",
                10,
                0,
            );
        }

        // Age historical command associations only while the
        // system is operating normally.
        decay_timer += 1;

        if (decay_timer >= DECAY_INTERVAL) {
            decayHabits();
            decay_timer = 0;
        }
    }
}

/// Return true if the system is healthy enough to perform
/// disk-intensive persistence operations.
pub fn canSave() bool {
    return current_state == .Optimal;
}

/// Main Conductor heartbeat.
///
/// Intended to be called periodically to refresh telemetry and
/// reassess overall system health.
pub fn tick() void {

    // Refresh vitals collected from the underlying system.
    vitals.update();

    // Re-evaluate the current operating state.
    evaluateTempo();
}

/// Gradually reduce all transition weights by approximately 10%.
///
/// This causes older behavioural patterns to fade over time unless
/// reinforced by continued usage.
pub fn decayHabits() void {
    for (&transition_table) |*row| {
        for (row) |*cell| {
            if (cell.* > 0) {

                // Promote to u32 before multiplication to avoid
                // overflowing the stored u16 value.
                const scaled: u32 = (@as(u32, cell.*) * 9) / 10;

                cell.* = @intCast(scaled);
            }
        }
    }
}

/// Return the learned transition weight between two commands.
///
/// A score of zero indicates the sequence has never been observed.
pub fn getScore(prev: conf.CommandID, curr: conf.CommandID) u16 {
    const p_idx = @intFromEnum(prev);
    const c_idx = @intFromEnum(curr);

    // Defensive bounds check against table dimensions.
    if (p_idx >= transition_table.len or
        c_idx >= transition_table[0].len)
        return 0;

    return transition_table[p_idx][c_idx];
}

/// Return the highest transition score originating from `prev`.
pub fn getTopScoreInRow(prev: conf.CommandID) u16 {
    const row = @intFromEnum(prev);

    // Defensive safety fence against invalid indices.
    if (row >= 16) return 0;

    var max_score: u16 = 0;

    for (0..16) |col| {
        const score = transition_table[row][col];

        if (score > max_score) {
            max_score = score;
        }
    }

    return max_score;
}
