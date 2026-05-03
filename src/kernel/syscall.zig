// src/kernel/fs/syscall.zig

const std = @import("std");
const conductor = @import("conductor.zig");
const conf = @import("config.zig");
const vga = @import("vga.zig");

pub const SyscallID = enum(u32) {
    WRITE_TEXT = 0,
    GET_TEMPO = 1,
    RECORD_HABIT = 2,
};

pub fn call(id: SyscallID, arg1: u64, arg2: u64) u64 {
    return switch (id) {
        .WRITE_TEXT => {
            const ptr: [*]const u8 = @ptrFromInt(arg1);
            const len: usize = @intCast(arg2);
            vga.writeString(ptr[0..len], 0x07, 0);
            return 0;
        },
        .GET_TEMPO => {
            // Returns the enum value (Optimal, Discordant, etc.)
            return @intFromEnum(conductor.current_state);
        },
        .RECORD_HABIT => {
            // mask the input to ensure it's just the byte value
            const p_raw = @as(u8, @intCast(arg1 & 0xFF));
            const c_raw = @as(u8, @intCast(arg2 & 0xFF));

            // SAFETY: Your table is 16x16.
            // We must reject anything index 16 or higher (0-15 are the only valid slots).
            if (p_raw >= 16 or c_raw >= 16) {
                return 0;
            }

            const prev = @as(conf.CommandID, @enumFromInt(p_raw));
            const curr = @as(conf.CommandID, @enumFromInt(c_raw));

            // 1. Get scores safely
            const current_score = conductor.getScore(prev, curr);
            const top_score = conductor.getTopScoreInRow(prev);

            // 2. Calculate Surprise (Top minus Current)
            var surprise: u16 = 0;
            if (top_score > current_score) {
                surprise = top_score - current_score;
            }

            // 3. Logic: Is it a surprise?
            // We'll set a high threshold (80) so it's not too sensitive yet.
            const is_anomaly = (surprise > 100 and current_score < 40);

            // 4. Update the table (Learning)
            // We use p_raw and c_raw directly as indices to be safe
            if (conductor.transition_table[p_raw][c_raw] < 65525) {
                conductor.transition_table[p_raw][c_raw] += 10;
            }

            return if (is_anomaly) @as(u64, 1) else @as(u64, 0);
        },
    };
}
