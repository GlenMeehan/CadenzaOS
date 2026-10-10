// src/kernel/E820.zig
//
// Read-only access to the kernel-owned E820 memory map.
//
// E820Store.zig copies the bootloader-provided E820 table into a
// kernel-owned memory region during early boot. This module stores
// the address and entry count of that copied table and provides
// indexed access to its contents.
//
// Responsibilities:
//   • Store the address and entry count of the copied E820 table
//   • Provide bounds-checked access to individual entries
//
// This module neither copies nor modifies the table contents.
//
pub const E820Entry = extern struct {
    base:       u64, // Physical start address of the memory region
    length:     u64, // Size of the region in bytes
    entry_type: u32, // E820 memory type (1 = usable RAM)
    acpi:       u32, // Extended ACPI attributes for this region
};

// -----------------------------------------------------------------------------
//  INTERNAL STATE (INITIALISED BY E820Store.init())
// -----------------------------------------------------------------------------

/// Address of the first entry in the kernel-owned E820 table.
var table_addr: usize = 0;

/// Total number of valid entries in the table.
var table_count: usize = 0;

// -----------------------------------------------------------------------------
//  PUBLIC API
// -----------------------------------------------------------------------------

/// Register the location and size of the kernel-owned E820 table.
///
/// Called once during early boot after E820Store has copied the
/// bootloader memory map into safe kernel-managed memory.
pub fn setTable(addr: usize, count: usize) void {
    table_addr = addr;
    table_count = count;
}

/// Return the number of valid E820 entries currently available.
pub fn getCount() usize {
    return table_count;
}

/// Return the E820 entry at the specified index.
///
/// Returns null if the index is outside the valid table range.
///
/// The entry is returned by value rather than by pointer, avoiding
/// lifetime, aliasing, and alignment concerns for callers.
pub fn getEntry(index: usize) ?E820Entry {
    if (index >= table_count) return null;

    const addr = table_addr + index * @sizeOf(E820Entry);
    const ptr  = @as(*const E820Entry, @ptrFromInt(addr));
    return ptr.*;
}
