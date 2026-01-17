// src/kernel/boot_info.zig
//
// BootInfo is a small structure placed by the bootloader at a fixed,
// well‑known physical address (0x7000). It contains essential metadata
// about the kernel image, memory map, and early paging structures.
//
// This module simply provides typed access to that structure.

/// Layout of the bootloader‑provided BootInfo block.
/// Must match exactly what your bootloader writes.
pub const BootInfo = extern struct {
    kernel_start: u64,       // 0x00 — physical start of kernel image
    kernel_end: u64,         // 0x08 — physical end of kernel image
    kernel_size: u64,        // 0x10 — size in bytes
    stack_top: u64,          // 0x18 — top of initial kernel stack

    e820_count: u32,         // 0x20 — number of E820 entries
    _padding: u32,           // 0x24 — alignment padding

    e820_addr: u64,          // 0x28 — physical address of E820 array
    page_table_base: u64,    // 0x30 — physical address of early page tables
};

/// Physical address where the bootloader places the BootInfo struct.
/// This must match your bootloader’s contract.
const BOOT_INFO_ADDR = 0x7000;

/// Return a pointer to the BootInfo structure.
///
/// The returned pointer refers to physical memory directly mapped
/// into the kernel’s address space (identity‑mapped early on).
pub fn get() *const BootInfo {
    return @as(*const BootInfo, @ptrFromInt(BOOT_INFO_ADDR));
}
