// src/kernel/e820_test.zig
//
// Diagnostic utilities for inspecting and validating the E820 memory map.
// These helpers are intended for early-kernel debugging and development
// purposes only and should not be used by production code.
//
// Provides:
//   • printEntry()        — Display a formatted E820 entry
//   • test1/test2/test3   — Basic iterator validation tests
//   • testIteratorState() — Inspect iterator state transitions
//
const e820 = @import("E820.zig");
const vga  = @import("vga.zig");
const conv = @import("convert.zig");

const E820Entry = e820.E820Entry;

// -----------------------------------------------------------------------------
//  ENTRY PRINTING HELPERS
// -----------------------------------------------------------------------------

/// Display a single E820 memory map entry in a human-readable format.
/// Useful when verifying BIOS-provided memory map contents.
fn printEntry(prefix: []const u8, entry: E820Entry) void {
    var buf: [32]u8 = undefined;

    vga.writeString(prefix, 15, 4);

    vga.writeString(" base=", 15, 4);
    vga.writeString(conv.toHex(u64, entry.base, &buf), 15, 4);

    vga.writeString(" length=", 15, 4);
    vga.writeString(conv.toHex(u64, entry.length, &buf), 15, 4);

    vga.writeString(" type=", 15, 4);
    vga.writeString(conv.toHex(u32, entry.entry_type, &buf), 15, 4);

    vga.writeString("\n", 15, 4);
}

// -----------------------------------------------------------------------------
//  BASIC ITERATOR TESTS
// -----------------------------------------------------------------------------

/// Retrieve and display the first E820 entry.
/// Confirms that the iterator can return an initial record.
pub fn test1() void {
    var it = e820.iterate();
    const first = it.next() orelse unreachable;
    printEntry("test1:", first);
}

/// Retrieve and display the first E820 entry using a fresh iterator.
/// Intended to verify consistent iterator initialisation.
pub fn test2() void {
    var it = e820.iterate();
    const first = it.next() orelse unreachable;
    printEntry("test2:", first);
}

/// Retrieve and display the first E820 entry using a fresh iterator.
/// Serves as an additional sanity check during debugging.
pub fn test3() void {
    var it = e820.iterate();
    const first = it.next() orelse unreachable;
    printEntry("test3:", first);
}

// -----------------------------------------------------------------------------
//  ITERATOR STATE INSPECTION
// -----------------------------------------------------------------------------

/// Display iterator state before and after advancing to the next entry.
/// Useful when verifying iterator progression and internal bookkeeping.
pub fn testIteratorState(label: []const u8) void {
    var it = e820.iterate();
    var buf: [32]u8 = undefined;

    // Iterator state before the first call to next().
    vga.writeString(label, 15, 4);
    vga.writeString(" BEFORE1 current=", 15, 4);
    vga.writeString(conv.toHex(u32, it.current, &buf), 15, 4);
    vga.writeString(" count=", 15, 4);
    vga.writeString(conv.toHex(u32, it.count, &buf), 15, 4);
    vga.writeString("\n", 15, 4);

    const first = it.next() orelse unreachable;

    // Iterator state after the first call and before the second.
    vga.writeString(label, 15, 4);
    vga.writeString(" BEFORE2 current=", 15, 4);
    vga.writeString(conv.toHex(u32, it.current, &buf), 15, 4);
    vga.writeString(" count=", 15, 4);
    vga.writeString(conv.toHex(u32, it.count, &buf), 15, 4);
    vga.writeString("\n", 15, 4);

    const second = it.next() orelse unreachable;

    // Explicitly mark retrieved entries as intentionally unused.
    _ = first;
    _ = second;
}
