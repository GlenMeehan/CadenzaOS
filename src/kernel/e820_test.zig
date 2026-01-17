// src/kernel/e820_test.zig
//
// Small diagnostic helpers for inspecting the E820 memory map
// and verifying iterator behaviour. These are intended for
// early debugging only and should not be used in production code.

const e820 = @import("E820.zig");
const vga = @import("vga.zig");
const conv = @import("convert.zig");

const E820Entry = e820.E820Entry;

/// Print a single E820 entry with a prefix label.
/// Useful for quick debugging.
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

/// Test 1 — print the first E820 entry
pub fn test1() void {
    var it = e820.iterate();
    const first = it.next() orelse unreachable;
    printEntry("test1:", first);
}

/// Test 2 — print the first E820 entry again
pub fn test2() void {
    var it = e820.iterate();
    const first = it.next() orelse unreachable;
    printEntry("test2:", first);
}

/// Test 3 — print the first E820 entry again
pub fn test3() void {
    var it = e820.iterate();
    const first = it.next() orelse unreachable;
    printEntry("test3:", first);
}

/// Inspect iterator internal state before and after advancing.
/// Useful for verifying that the iterator implementation behaves correctly.
pub fn testIteratorState(label: []const u8) void {
    var it = e820.iterate();
    var buf: [32]u8 = undefined;

    // Before first next()
    vga.writeString(label, 15, 4);
    vga.writeString(" BEFORE1 current=", 15, 4);
    vga.writeString(conv.toHex(u32, it.current, &buf), 15, 4);
    vga.writeString(" count=", 15, 4);
    vga.writeString(conv.toHex(u32, it.count, &buf), 15, 4);
    vga.writeString("\n", 15, 4);

    const first = it.next() orelse unreachable;

    // Before second next()
    vga.writeString(label, 15, 4);
    vga.writeString(" BEFORE2 current=", 15, 4);
    vga.writeString(conv.toHex(u32, it.current, &buf), 15, 4);
    vga.writeString(" count=", 15, 4);
    vga.writeString(conv.toHex(u32, it.count, &buf), 15, 4);
    vga.writeString("\n", 15, 4);

    const second = it.next() orelse unreachable;

    // Silence unused variable warnings
    _ = first;
    _ = second;
}
