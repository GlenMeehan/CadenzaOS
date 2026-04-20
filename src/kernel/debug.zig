// src/kernel/debug.zig
//
// Early debugging helpers for inspecting the raw E820 table
// directly from its physical location (0x0009_0000).
//
// WARNING:
//   • This bypasses E820Store and reads BIOS-provided memory directly.
//   • Only valid during very early boot on your specific bootloader.
//   • Not portable, not safe, not for production.
//
// Modern code should use:
//     E820Store.init()
//     e820.getEntry()
// instead of reading raw memory.

const vga  = @import("vga.zig");
const e820 = @import("E820.zig");
const conv = @import("convert.zig");

// -----------------------------------------------------------------------------
//  RAW MEMORY CONSTANTS
// -----------------------------------------------------------------------------

/// Physical address where your bootloader places the E820 table.
/// Not guaranteed on real hardware — only valid for your environment.
const PHYS_E820: usize = 0x0009_0000;

/// Size of each E820 entry in bytes (base + length + type + acpi)
const ENTRY_SIZE: usize = 24;

// -----------------------------------------------------------------------------
//  RAW MEMORY ACCESS HELPERS
// -----------------------------------------------------------------------------

/// Compute the physical address of a field inside an E820 entry.
fn addr(entry: usize, offset: usize) usize {
    return PHYS_E820 + entry * ENTRY_SIZE + offset;
}

/// Read a 64‑bit value from a physical address.
fn readU64(a: usize) u64 {
    return @as(*volatile u64, @ptrFromInt(a)).*;
}

/// Read a 32‑bit value from a physical address.
fn readU32(a: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(a)).*;
}

// -----------------------------------------------------------------------------
//  DEBUG DUMP
// -----------------------------------------------------------------------------

/// Dump the first E820 entry directly from physical memory.
/// Legacy debugging helper — use only during bring‑up.
pub fn dumpFirstEntries() void {
    const base0 = readU64(addr(0, 0));
    const len0  = readU64(addr(0, 8));
    const type0 = readU32(addr(0, 16));
    const acpi0 = readU32(addr(0, 20));

    var bufa: [64]u8 = undefined;
    vga.writeStringAt(10, 0,  conv.toHex(u64, base0, bufa[0..]), 15, 0);

    var bufb: [64]u8 = undefined;
    vga.writeStringAt(10, 18, conv.toHex(u64, len0, bufb[0..]), 15, 0);

    var bufc: [32]u8 = undefined;
    vga.writeStringAt(10, 35, conv.toHex(u32, type0, bufc[0..]), 15, 0);

    var bufd: [32]u8 = undefined;
    vga.writeStringAt(10, 44, conv.toHex(u32, acpi0, bufd[0..]), 15, 0);
}

// -----------------------------------------------------------------------------
//  PAUSE / BREAKPOINT
// -----------------------------------------------------------------------------

/// Halt the CPU forever — useful for breakpoints or debugging pauses.
pub fn pause() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}
