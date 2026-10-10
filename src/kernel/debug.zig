// src/kernel/debug.zig
//
// Early debugging helpers for inspecting the raw E820 table
// directly from its physical location (0x0009_0000).
//
// WARNING:
//   • Bypasses E820Store and reads bootloader-populated memory directly
//   • Valid only during early bring-up on the current boot path
//   • Not portable and not intended for production use
//
// Modern code should use:
//     E820Store.init()
//     e820.getEntry()
// instead of accessing E820 data via hard-coded addresses.

const vga  = @import("vga.zig");
const e820 = @import("E820.zig");
const conv = @import("convert.zig");

// -----------------------------------------------------------------------------
//  RAW MEMORY CONSTANTS
// -----------------------------------------------------------------------------

/// Physical address where the bootloader places the E820 table.
///
/// This address is part of the current bootloader contract and should
/// not be assumed valid on other systems or boot configurations.
const PHYS_E820: usize = 0x0009_0000;

/// Size of a single E820 entry.
///
/// Layout:
///   base address   (u64)
///   length         (u64)
///   type           (u32)
///   ACPI attribute (u32)
const ENTRY_SIZE: usize = 24;

// -----------------------------------------------------------------------------
//  RAW MEMORY ACCESS HELPERS
// -----------------------------------------------------------------------------

/// Compute the physical address of a field within an E820 entry.
fn addr(entry: usize, offset: usize) usize {
    return PHYS_E820 + entry * ENTRY_SIZE + offset;
}

/// Read a 64-bit value from a physical address.
fn readU64(a: usize) u64 {
    return @as(*volatile u64, @ptrFromInt(a)).*;
}

/// Read a 32-bit value from a physical address.
fn readU32(a: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(a)).*;
}

// -----------------------------------------------------------------------------
//  DEBUG DUMP
// -----------------------------------------------------------------------------

/// Dump the first E820 entry directly from physical memory.
///
/// Useful during memory-map bring-up to verify that the bootloader
/// populated the table correctly before higher-level parsing code
/// is trusted.
pub fn dumpFirstEntries() void {
    const base0 = readU64(addr(0, 0));
    const len0  = readU64(addr(0, 8));
    const type0 = readU32(addr(0, 16));
    const acpi0 = readU32(addr(0, 20));

    var bufa: [64]u8 = undefined;
    vga.writeStringAt(10, 0, conv.toHex(u64, base0, bufa[0..]), 15, 0);

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

/// Halt the CPU indefinitely.
///
/// Useful as a simple kernel breakpoint during bring-up and early
/// debugging when no debugger is attached.
pub fn pause() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}
