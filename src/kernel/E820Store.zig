// src/kernel/E820Store.zig
//
// This module copies the bootloader-provided E820 memory map
// into kernel-owned memory. The bootloader's memory may not be
// safe to access after early boot, so we duplicate it here.
//
// Responsibilities:
//   • Copy E820 entries from boot_info.zig
//   • Store them in a static kernel buffer
//   • Provide safe access to the copied table
//
// This module does NOT interpret the entries — that is handled
// by frame_allocator.zig.

const bi = @import("boot_info.zig");
const e820 = @import("E820.zig");
const mem = @import("memory.zig");

pub const E820Entry = e820.E820Entry;

const MAX_E820_ENTRIES = 64;

// Kernel-owned storage for the copied E820 table.
// Lives in .bss/.data and is safe to access at any time.
var table: [MAX_E820_ENTRIES]E820Entry = undefined;
var table_count: u32 = 0;

/// Return the physical address of the first copied entry.
/// Used by E820.zig to read from the safe table.

pub fn getTableAddr() usize {
    const virt = @intFromPtr(&table[0]);
    return mem.virtToPhys(virt);
}

/// Return how many entries were copied.
pub fn getTableCount() u32 {
    return table_count;
}

/// Copy the E820 table from boot_info into kernel-owned memory.
///
/// The bootloader provides:
///   • e820_addr  → physical address of the E820 array
///   • e820_count → number of entries
///
/// We copy up to MAX_E820_ENTRIES entries into `table[]`.
pub fn init() void {
    const boot = bi.get();
    const count = boot.e820_count;

    // Clamp to our fixed-size buffer
    table_count = if (count > MAX_E820_ENTRIES)
    MAX_E820_ENTRIES
    else
        count;

    const src_base = boot.e820_addr;

    // Copy entries one by one
    var i: u32 = 0;
    while (i < table_count) : (i += 1) {
        const src_addr = src_base + @as(usize, i) * @sizeOf(E820Entry);
        const src_ptr = @as(*const E820Entry, @ptrFromInt(src_addr));
        table[i] = src_ptr.*;
    }
}
