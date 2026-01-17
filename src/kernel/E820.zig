// src/kernel/E820.zig
//
// This module provides read‑only access to the E820 memory map
// after it has been copied into kernel‑owned memory by E820Store.zig.
//
// Responsibilities:
//   • Hold the address + count of the copied E820 table
//   • Provide safe indexed access to entries
//
// This module does NOT copy or modify the table — it only reads it.

pub const E820Entry = extern struct {
    base: u64,        // physical base address
    length: u64,      // length in bytes
    entry_type: u32,  // 1 = usable RAM, others = reserved/ACPI/etc.
    acpi: u32,        // extended attributes (usually zero)
};

// Pointer to the kernel-owned E820 table (set by E820Store.init()).
var table_addr: usize = 0;

// Number of valid entries in the table.
var table_count: usize = 0;

/// Set the address and count of the safe E820 table.
/// Called once during early boot by E820Store.init().
pub fn setTable(addr: usize, count: usize) void {
    table_addr = addr;
    table_count = count;
}

/// Return the number of E820 entries.
pub fn getCount() usize {
    return table_count;
}

/// Return the E820 entry at the given index, or null if out of bounds.
///
/// The returned entry is copied by value, so callers do not need to worry
/// about pointer lifetime or alignment.
pub fn getEntry(index: usize) ?E820Entry {
    if (index >= table_count) return null;

    const addr = table_addr + index * @sizeOf(E820Entry);
    const ptr = @as(*const E820Entry, @ptrFromInt(addr));
    return ptr.*;
}
