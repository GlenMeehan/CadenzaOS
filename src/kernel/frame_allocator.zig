// src/kernel/frame_allocator.zig
//
// Extracts usable memory regions from the E820 map and exposes them
// to the rest of the kernel. This module does NOT allocate frames —
// that is handled by bitmap.zig.
//
// Responsibilities:
//   • Read E820 entries
//   • Filter usable regions (type 1, above 1 MiB)
//   • Store them in a compact internal array
//   • Provide them to the bitmap/frame allocator

const std = @import("std");
const e820 = @import("E820.zig");
const vga = @import("vga.zig");
const conv = @import("convert.zig");
const bm = @import("bitmap.zig");

// -----------------------------------------------------------------------------
//  REGION STRUCTURE + STORAGE
// -----------------------------------------------------------------------------

pub const Region = struct {
    base: usize,
    length: usize,
};

var usable_regions: [16]Region = undefined;
var usable_region_count: usize = 0;

/// Return a slice of all usable memory regions discovered.
pub fn getUsableRegions() []const Region {
    return usable_regions[0..usable_region_count];
}

// -----------------------------------------------------------------------------
//  FRAME ALLOCATOR (E820 PARSING ONLY)
// -----------------------------------------------------------------------------

pub const FrameAllocator = struct {

    /// Debug-print all E820 entries (base, length, type).
    /// This does not filter or store anything — purely diagnostic.
    pub fn init() void {
        var row: u16 = 4;

        for (0..e820.getCount()) |i| {
            const entry = e820.getEntry(i).?;

            var buf_base: [16]u8 = undefined;
            var buf_len:  [16]u8 = undefined;
            var buf_type: [8]u8  = undefined;

            vga.writeStringAt(row, 0,  "Base: ", 15, 0);
            vga.writeStringAt(row, 6,  conv.toHex(u64, entry.base, &buf_base), 15, 0);

            vga.writeStringAt(row, 23, "Len: ", 15, 0);
            vga.writeStringAt(row, 28, conv.toHex(u64, entry.length, &buf_len), 15, 0);

            vga.writeStringAt(row, 45, "Type: ", 15, 0);
            vga.writeStringAt(row, 51, conv.toHex(u32, entry.entry_type, &buf_type), 15, 0);

            row += 1;
            if (row >= 24) break; // avoid scrolling during early boot
        }
    }

    /// Parse the E820 table and extract usable memory regions.
    /// Rules:
    ///   • Only type 1 (usable RAM)
    ///   • Only memory above 1 MiB (avoid BIOS/low-memory holes)
    pub fn parseUsableMemory() void {
        const ONE_MB = 1024 * 1024;

        for (0..e820.getCount()) |i| {
            const entry = e820.getEntry(i).?;

            // Only type 1 = usable RAM
            if (entry.entry_type != 1) continue;

            const region_end = entry.base + entry.length;

            // Skip regions entirely below 1 MiB
            if (region_end <= ONE_MB) continue;

            // Clamp start to >= 1 MiB
            const usable_base = @max(entry.base, ONE_MB);
            const usable_length = region_end - usable_base;

            usable_regions[usable_region_count] = .{
                .base   = usable_base,
                .length = usable_length,
            };
            usable_region_count += 1;

            // Debug output
            var buf_ub: [16]u8 = undefined;
            var buf_ul: [16]u8 = undefined;

            vga.writeString("Usable base: ", 15, 0);
            vga.writeString(conv.toHex(u64, usable_base, &buf_ub), 15, 0);

            vga.writeString("Usable len:  ", 15, 0);
            vga.writeString(conv.toHex(u64, usable_length, &buf_ul), 15, 0);
        }
    }
};
