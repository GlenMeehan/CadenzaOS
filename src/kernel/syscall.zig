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
            const prev_idx = @as(usize, @intCast(arg1));
            const curr_idx = @as(usize, @intCast(arg2));

            // Safety check against the count in config
            const max = std.enums.values(conf.CommandID).len;
            if (prev_idx < max and curr_idx < max) {
                if (conductor.transition_table[prev_idx][curr_idx] < 65525) {
                    conductor.transition_table[prev_idx][curr_idx] += 10;
                } else {
                    conductor.transition_table[prev_idx][curr_idx] = 65535;
                }
            }
            return 0;
        },
    };
}
