// src/kernel/boot_info.zig
//
// Typed access to the BootInfo structure written by the bootloader
// at a fixed physical address (0x7000).
//
// BootInfo provides early-boot information required before the kernel
// has fully initialised its own memory management and hardware layers.
//
// Contents include:
//   • Kernel image physical range
//   • Initial kernel stack location
//   • E820 memory map address and entry count
//   • Early page table base address
//   • Framebuffer configuration
//
// This structure is owned by the bootloader. The kernel treats it as
// read-only and does not modify its contents.

/// Must exactly match the layout written by the bootloader.
///
/// Field offsets form part of the bootloader/kernel ABI contract.
/// Changes require matching updates on both sides.
pub const BootInfo = extern struct {
    kernel_start:    u64, // 0x00 — physical start of kernel image
    kernel_end:      u64, // 0x08 — physical end of kernel image
    kernel_size:     u64, // 0x10 — kernel size in bytes
    stack_top:       u64, // 0x18 — top of initial kernel stack

    e820_count:      u32, // 0x20 — number of E820 memory map entries
    graphics_mode:   u32, // 0x24 — bootloader-selected graphics mode

    e820_addr:       u64, // 0x28 — physical address of E820 entry array
    page_table_base: u64, // 0x30 — physical address of early page tables

    framebuffer_addr: u64, // 0x38 — linear framebuffer physical address

    fb_stride:       u64, // 0x40 — bytes per scan line
    fb_width:        u64, // 0x48 — framebuffer width in pixels
    fb_height:       u64, // 0x50 — framebuffer height in pixels
    fb_bpp:          u64, // 0x58 — bits per pixel

    // Framebuffer colour channel layout.
    // These values describe the pixel format reported by the firmware.
    red_mask_size:   u64, // 0x60
    red_position:    u64, // 0x68
    green_mask_size: u64, // 0x70
    green_position:  u64, // 0x78
    blue_mask_size:  u64, // 0x80
    blue_position:   u64, // 0x88
    rsvd_mask_size:  u64, // 0x90
    rsvd_position:   u64, // 0x98
};

comptime {
    // Detect bootloader/kernel ABI drift at compile time.
    if (@sizeOf(BootInfo) != 160) {
        @compileError("BootInfo struct size mismatch! Must be 160 bytes.");
    }
}

/// Physical address where the bootloader places the BootInfo structure.
///
/// Must remain synchronised with the bootloader implementation.
const BOOT_INFO_ADDR = 0x7000;

/// Return a pointer to the BootInfo structure.
///
/// During early boot this address is expected to be identity-mapped,
/// allowing direct access without virtual address translation.
pub fn get() *const BootInfo {
    return @as(*const BootInfo, @ptrFromInt(BOOT_INFO_ADDR));
}
