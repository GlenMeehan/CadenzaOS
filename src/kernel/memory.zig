// src/kernel/memory.zig

pub const KERNEL_OFFSET: usize = 0xFFFFFF8000000000;

pub fn physToVirt(phys: usize) usize {
    return phys + KERNEL_OFFSET;
}

pub fn virtToPhys(virt: usize) usize {
    return virt - KERNEL_OFFSET;
}
