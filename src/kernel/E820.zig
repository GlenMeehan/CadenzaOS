// src/kernel/E820.zig
//
// Read‑only access to the kernel‑owned E820 memory map.
//
// E820Store.zig copies the bootloader’s E820 table into safe,
// kernel‑owned memory. This module simply holds the address/count
// of that copied table and provides indexed access.
//
// Responsibilities:
//   • Store pointer + count of copied E820 table
//   • Provide safe, bounds‑checked access to entries
//
// This module does NOT copy or modify the table.

pub const E820Entry = extern struct {
    base:       u64, // physical base address
    length:     u64, // length in bytes
    entry_type: u32, // 1 = usable RAM, others = reserved/ACPI/etc.
    acpi:       u32, // extended attributes (usually zero)
};

// -----------------------------------------------------------------------------
//  INTERNAL STATE (set once by E820Store.init())
// -----------------------------------------------------------------------------

var table_addr: usize = 0; // physical address of first entry
var table_count: usize = 0; // number of valid entries

// -----------------------------------------------------------------------------
//  PUBLIC API
// -----------------------------------------------------------------------------

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
    const ptr  = @as(*const E820Entry, @ptrFromInt(addr));
    return ptr.*;
}
