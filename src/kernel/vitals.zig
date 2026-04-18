// src/kernel/vitals.zig

pub const Vitals = struct {
    disk_cycles: u64 = 0,
    boot_timestamp: u64 = 0,
    last_read_latency: u64 = 0,
};

pub var current_vitals = Vitals{};
