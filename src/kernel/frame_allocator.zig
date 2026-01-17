// src/kernel/frame_allocator.zig
//
// This module extracts usable memory regions from the E820 map
// and exposes them to the rest of the kernel. It does NOT allocate
// frames itself — that is handled by bitmap.zig.
//
// Responsibilities:
//   • Read E820 entries
//   • Filter usable regions (type 1, above 1 MiB)
//   • Store them in a compact internal array
//   • Provide them to the bitmap/frame allocator
//
// This module is intentionally simple and low‑level.

const std = @import("std");
const e820 = @import("E820.zig");
const vga = @import("vga.zig");
const conv = @import("convert.zig");
const bm = @import("bitmap.zig");

/// A usable physical memory region (base + length).
pub const Region = struct {
    base: usize,
    length: usize,
};

/// Storage for up to 16 usable regions.
/// (Most machines only have 1–3 usable regions.)
var usable_regions: [16]Region = undefined;
var usable_region_count: usize = 0;

/// Return a slice of all usable regions discovered so far.
pub fn getUsableRegions() []const Region {
    return usable_regions[0..usable_region_count];
}

pub const FrameAllocator = struct {

    /// Debug: print the raw E820 table to the screen.
    /// This is purely diagnostic and does not affect allocation.
    pub fn init() void {
        var row: u16 = 4;

        for (0..e820.getCount()) |i| {
            const entry = e820.getEntry(i).?;

            // Base address
            var buf_base: [16]u8 = undefined;
            vga.writeStringAt(row, 0, "Base: ", 15, 0);
            vga.writeStringAt(row, 6, conv.toHex(u64, entry.base, &buf_base), 15, 0);

            // Length
            var buf_len: [16]u8 = undefined;
            vga.writeStringAt(row, 23, "Len: ", 15, 0);
            vga.writeStringAt(row, 28, conv.toHex(u64, entry.length, &buf_len), 15, 0);

            // Type
            var buf_type: [8]u8 = undefined;
            vga.writeStringAt(row, 45, "Type: ", 15, 0);
            vga.writeStringAt(row, 51, conv.toHex(u32, entry.entry_type, &buf_type), 15, 0);

            row += 1;
            if (row >= 24) break; // avoid scrolling off screen
        }
    }

    /// Parse the E820 table and extract usable memory regions.
    ///
    /// Rules:
    ///   • Only type 1 regions are usable
    ///   • Ignore anything below 1 MiB (reserved for BIOS/IVT/etc.)
    ///   • Clip regions that start below 1 MiB
    ///
    /// The resulting regions are stored in `usable_regions[]`.
    pub fn parseUsableMemory() void {
        const ONE_MB = 1024 * 1024;

        for (0..e820.getCount()) |i| {
            const entry = e820.getEntry(i).?;
            if (entry.entry_type != 1) continue; // only usable RAM

            const region_end = entry.base + entry.length;
            if (region_end <= ONE_MB) continue; // entirely below 1 MiB

            // Clip region so it starts at or above 1 MiB
            const usable_base = @max(entry.base, ONE_MB);
            const usable_length = region_end - usable_base;

            usable_regions[usable_region_count] = .{
                .base = usable_base,
                .length = usable_length,
            };
            usable_region_count += 1;

            // Debug output
            var buf_ub: [16]u8 = undefined;
            vga.writeString("Usable base: ", 15, 0);
            vga.writeString(conv.toHex(u64, usable_base, &buf_ub), 15, 0);

            var buf_ul: [16]u8 = undefined;
            vga.writeString("Usable len:  ", 15, 0);
            vga.writeString(conv.toHex(u64, usable_length, &buf_ul), 15, 0);
        }
    }
};
