// src/kernel/frame_allocator.zig
//
// Discovers usable physical memory regions from the E820 memory map
// and exposes them to the rest of the kernel.
//
// This module does not perform frame allocation itself. Its role is
// limited to identifying usable RAM ranges and storing them in a
// compact form for later consumption by bitmap.zig.
//
// Responsibilities:
//   • Read entries from the kernel-owned E820 table
//   • Select usable RAM regions (E820 type 1)
//   • Exclude memory below 1 MiB
//   • Store usable regions in an internal array
//   • Provide region information to the frame allocator
//
const std = @import("std");
const e820 = @import("E820.zig");
const vga = @import("vga.zig");
const conv = @import("convert.zig");
const bm = @import("bitmap.zig");

// -----------------------------------------------------------------------------
//  REGION STORAGE
// -----------------------------------------------------------------------------

/// Enable verbose VGA debug output.
///
/// When disabled, region discovery operates silently.
pub var verbose: bool = false;

/// Represents a contiguous range of usable physical memory.
pub const Region = struct {
    base: usize,
    length: usize,
};

/// Internal storage for discovered usable memory regions.
///
/// The E820 map is typically small, so a fixed-size array avoids
/// allocator dependencies during early boot.
var usable_regions: [64]Region = undefined;

/// Number of valid entries currently stored in usable_regions.
var usable_region_count: usize = 0;

/// Return a read-only slice containing all discovered usable regions.
pub fn getUsableRegions() []const Region {
    return usable_regions[0..usable_region_count];
}

pub const FrameAllocator = struct {

    /// Display raw E820 entries for debugging purposes.
    ///
    /// This function does not modify allocator state and exists purely
    /// to aid development and troubleshooting of memory-map handling.
    pub fn init() void {
        if (!verbose) return;

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
            if (row >= 24) break;
        }
    }

    /// Build the internal list of usable physical memory regions.
    ///
    /// Selection rules:
    ///   • Only E820 type 1 entries are accepted
    ///   • Any memory below 1 MiB is excluded
    ///   • Regions crossing the 1 MiB boundary are trimmed
    ///   • Excess regions are discarded rather than overflowing the
    ///     fixed-size storage array
    ///
    /// The resulting region list is later used by the bitmap-based
    /// frame allocator.
    pub fn parseUsableMemory() void {
        const ONE_MB = 1024 * 1024;

        for (0..e820.getCount()) |i| {
            const entry = e820.getEntry(i).?;

            // Ignore non-usable E820 region types.
            if (entry.entry_type != 1) continue;

            const region_end = entry.base + entry.length;

            // Ignore regions that lie entirely below 1 MiB.
            if (region_end <= ONE_MB) continue;

            // Trim regions that begin below 1 MiB so that only
            // memory above the conventional low-memory area remains.
            const usable_base = @max(entry.base, ONE_MB);
            const usable_length = region_end - usable_base;

            // Discard excess entries rather than writing beyond the
            // fixed-size region storage array.
            if (usable_region_count >= usable_regions.len) continue;

            usable_regions[usable_region_count] = .{
                .base   = usable_base,
                .length = usable_length,
            };
            usable_region_count += 1;

            if (!verbose) continue;

            var buf_ub: [16]u8 = undefined;
            var buf_ul: [16]u8 = undefined;

            vga.writeString("Usable base: ", 15, 0);
            vga.writeString(conv.toHex(u64, usable_base, &buf_ub), 15, 0);

            vga.writeString("Usable len:  ", 15, 0);
            vga.writeString(conv.toHex(u64, usable_length, &buf_ul), 15, 0);
        }
    }
};
