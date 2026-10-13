// src/kernel/fs/syscall.zig
//
// Filesystem and conductor subsystem syscall interface.
//
// Provides a small command-dispatch layer for invoking selected
// kernel services through a stable numeric syscall identifier.
//
// Current services:
//   • WRITE_TEXT   — output text to the display
//   • GET_TEMPO    — query the current conductor state
//   • RECORD_HABIT — record and analyse command transitions
//
const std = @import("std");
const conductor = @import("conductor.zig");
const conf = @import("config.zig");
const vga = @import("vga.zig");

/// Supported syscall identifiers.
pub const SyscallID = enum(u32) {
    WRITE_TEXT = 0,
    GET_TEMPO = 1,
    RECORD_HABIT = 2,
};

/// Execute a syscall request and return the resulting value.
///
/// Argument interpretation depends on the selected syscall.
pub fn call(id: SyscallID, arg1: u64, arg2: u64) u64 {
    return switch (id) {

        // ---------------------------------------------------------------------
        //  WRITE_TEXT
        // ---------------------------------------------------------------------
        //
        // Arguments:
        //   arg1 = pointer to UTF-8 text buffer
        //   arg2 = buffer length
        //
        // Returns:
        //   0
        //
        .WRITE_TEXT => {
            const ptr: [*]const u8 = @ptrFromInt(arg1);
            const len: usize = @intCast(arg2);

            vga.writeString(ptr[0..len], 0x07, 0);

            return 0;
        },

        // ---------------------------------------------------------------------
        //  GET_TEMPO
        // ---------------------------------------------------------------------
        //
        // Returns the current conductor-state enumeration value.
        //
        .GET_TEMPO => {
            return @intFromEnum(conductor.current_state);
        },

        // ---------------------------------------------------------------------
        //  RECORD_HABIT
        // ---------------------------------------------------------------------
        //
        // Arguments:
        //   arg1 = previous command identifier
        //   arg2 = current command identifier
        //
        // Records command transitions, updates the learning model,
        // and reports whether the transition appears anomalous.
        //
        // Returns:
        //   1 = anomalous transition detected
        //   0 = transition considered normal
        //
        .RECORD_HABIT => {

            // Constrain inputs to a single byte before processing.
            const p_raw = @as(u8, @intCast(arg1 & 0xFF));
            const c_raw = @as(u8, @intCast(arg2 & 0xFF));

            // Protect the transition table against invalid indices.
            //
            // The current implementation maintains a fixed 16x16
            // transition matrix.
            if (p_raw >= 16 or c_raw >= 16) {
                return 0;
            }

            const prev = @as(conf.CommandID, @enumFromInt(p_raw));
            const curr = @as(conf.CommandID, @enumFromInt(c_raw));

            // Retrieve the current transition score and the most
            // frequently observed transition originating from the
            // same source command.
            const current_score = conductor.getScore(prev, curr);
            const top_score = conductor.getTopScoreInRow(prev);

            // Measure how unusual the observed transition is relative
            // to the strongest known transition for this command.
            var surprise: u16 = 0;

            if (top_score > current_score) {
                surprise = top_score - current_score;
            }

            // Classify unusually weak transitions as anomalies.
            //
            // Current thresholds are intentionally conservative.
            const is_anomaly =
            (surprise > 100 and current_score < 40);

            // Update the transition model to incorporate this newly
            // observed behaviour.
            //
            // Saturate near the u16 limit to prevent overflow.
            if (conductor.transition_table[p_raw][c_raw] < 65525) {
                conductor.transition_table[p_raw][c_raw] += 10;
            }

            return if (is_anomaly)
            @as(u64, 1)
            else
                @as(u64, 0);
        },
    };
}
