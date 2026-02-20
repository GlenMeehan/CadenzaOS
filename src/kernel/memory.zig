// src/kernel/memory.zig

pub const KERNEL_OFFSET: usize = 0xFFFFFF8000000000;

pub fn physToVirt(phys: usize) usize {
    return phys + KERNEL_OFFSET;
}

pub fn virtToPhys(virt: usize) usize {
    return virt - KERNEL_OFFSET;
}

pub export fn memcpy(dest: [*]u8, src: [*]const u8, n: usize) [*]u8 {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        dest[i] = src[i];
    }
    return dest;
}

pub export fn memset(dest: [*]u8, value: u8, n: usize) [*]u8 {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        dest[i] = value;
    }
    return dest;
}

pub fn eqlNoSimd(comptime T: type, a: []const T, b: []const T) bool {
    if (a.len != b.len) return false;
    if (a.ptr == b.ptr) return true;

    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

