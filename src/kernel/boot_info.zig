// src/kernel/boot_info.zig
//
// Typed access to the BootInfo structure placed by the bootloader
// at a fixed physical address (0x7000).
//
// BootInfo contains:
//   • Kernel image physical range
//   • Initial stack top
//   • E820 table address + count
//   • Early page table base
//
// The kernel does NOT modify this structure — it only reads it.

/// Must match the exact layout written by the bootloader.
/// Offsets are fixed and part of the boot contract.
pub const BootInfo = extern struct {
    kernel_start:    u64, // 0x00 — physical start of kernel image
    kernel_end:      u64, // 0x08 — physical end of kernel image
    kernel_size:     u64, // 0x10 — size in bytes
    stack_top:       u64, // 0x18 — top of initial kernel stack

    e820_count:      u32, // 0x20 — number of E820 entries
    _padding:        u32, // 0x24 — alignment padding

    e820_addr:       u64, // 0x28 — physical address of E820 array
    page_table_base: u64, // 0x30 — physical address of early page tables
};

/// Physical address where the bootloader places BootInfo.
/// Must match the bootloader’s contract exactly.
const BOOT_INFO_ADDR = 0x7000;

/// Return a pointer to the BootInfo structure.
///
/// This address is identity‑mapped during early boot, so the kernel
/// can safely dereference it without translation.
pub fn get() *const BootInfo {
    return @as(*const BootInfo, @ptrFromInt(BOOT_INFO_ADDR));
}
