// src/kernel/debug.zig
//
// Early debugging helpers for inspecting the raw E820 table
// directly from its physical location (0x0009_0000).
//
// NOTE:
//   This bypasses E820Store and reads memory directly from BIOS‑provided
//   physical RAM. It is useful only for very early debugging and should
//   not be used in production code.
//
//   Modern code should use:
//       E820Store.init()
//       e820.getEntry()
//   instead of reading raw memory.

const vga = @import("vga.zig");
const e820 = @import("E820.zig");
const conv = @import("convert.zig");

/// Physical address where BIOS places the E820 table.
/// This is *not* guaranteed on all systems — only valid for your bootloader.
const PHYS_E820: usize = 0x0009_0000;

/// Size of each E820 entry in bytes (base + length + type + acpi)
const ENTRY_SIZE: usize = 24;

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

/// Dump the first E820 entry directly from physical memory.
/// This is a legacy debugging helper.
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

/// Halt the CPU forever — useful for breakpoints or debugging pauses.
pub fn pause() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}
