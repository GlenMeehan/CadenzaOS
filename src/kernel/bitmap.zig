const std = @import("std");
const frame_allocator = @import("frame_allocator.zig");
const Region = frame_allocator.Region;
const vga = @import("vga.zig");
const mem = @import("memory.zig");

pub const PAGE_SIZE: usize = 4096;

// ------------------------------------------------------------
// Global bitmap storage
// ------------------------------------------------------------
//
// This bitmap tracks physical page usage.
// Each bit represents one 4 KiB page:
//   0 = free
//   1 = used
//
// The static array below supports up to ~1 GiB of RAM
// (32768 bytes * 8 bits = 262,144 pages * 4096 bytes = 1 GiB).
// ------------------------------------------------------------

var bitmap_storage: [32768]u8 = [_]u8{0xFF} ** 32768; // start with all pages marked used
var bitmap: []u8 = bitmap_storage[0..];

var total_pages: usize = 0;

// ------------------------------------------------------------
// Internal helpers
// ------------------------------------------------------------

/// Compute how many bytes are needed to represent `pages` bits.
fn computeBitmapSize(pages: usize) usize {
    return (pages + 7) / 8;
}

/// Mark a page as free (bit = 0)
fn markFree(page_index: usize) void {
    const byte_index = page_index / 8;
    const bit_index = page_index % 8;
    bitmap[byte_index] &= ~( @as(u8, 1) << @intCast(bit_index) );
}

/// Mark a page as used (bit = 1)
fn markUsed(page_index: usize) void {
    const byte_index = page_index / 8;
    const bit_index = page_index % 8;
    bitmap[byte_index] |= (@as(u8, 1) << @intCast(bit_index));
}

// ------------------------------------------------------------
// Initialization
// ------------------------------------------------------------

/// Initialize the bitmap using the list of usable memory regions.
/// All pages start as "used", and usable pages are flipped to "free".
pub fn init(regions: []const Region) void {
    // 1. Count total pages across all usable regions
    var total: usize = 0;
    for (regions) |r| {
        total += r.length / PAGE_SIZE;
    }
    total_pages = total;

    // 2. Ensure the static bitmap is large enough
    const needed_bytes = computeBitmapSize(total_pages);
    if (needed_bytes > bitmap.len) {
        @panic("Bitmap storage too small for available memory");
    }

    // 3. Mark all usable pages as free
    for (regions) |r| {
        const start_page = r.base / PAGE_SIZE;
        const page_count = r.length / PAGE_SIZE;

        var i: usize = 0;
        while (i < page_count) : (i += 1) {
            markFree(start_page + i);
        }
    }
}

/// Mark a physical address range as used.
/// `end_phys` is exclusive.
pub fn markUsedRange(start_phys: usize, end_phys: usize) void {
    const start_page = start_phys / PAGE_SIZE;
    const end_page = (end_phys + PAGE_SIZE - 1) / PAGE_SIZE;

    var page = start_page;
    while (page < end_page) : (page += 1) {
        markUsed(page);
    }
}

/// Return the physical address range occupied by the bitmap itself.
/// This must be marked as used so the allocator never hands it out.
const KERNEL_OFFSET: usize = 0xFFFFFF8000000000;

pub fn getStorageRange() struct { start: usize, end: usize } {
    const virt_start = @intFromPtr(&bitmap_storage[0]);
    const virt_end   = virt_start + bitmap_storage.len;

    const phys_start = mem.virtToPhys(virt_start);
    const phys_end   = mem.virtToPhys(virt_end);


    return .{ .start = phys_start, .end = phys_end };
}

// ------------------------------------------------------------
// Allocation
// ------------------------------------------------------------

/// Find the first free page in the bitmap.
/// Returns the page index or null if none are free.
fn findFirstFree() ?usize {
    for (bitmap, 0..) |byte, byte_index| {
        if (byte == 0xFF) continue; // all 8 pages used

        // At least one bit is free in this byte
        var bit_index: u3 = 0;
        while (bit_index < 8) : (bit_index += 1) {
            const mask = @as(u8, 1) << bit_index;
            if ((byte & mask) == 0) {
                const page_index = byte_index * 8 + bit_index;
                if (page_index < total_pages) {
                    return page_index;
                }
            }
        }
    }
    return null;
}

/// Check if a page is currently marked used.
fn isUsed(page_index: usize) bool {
    const byte_index = page_index / 8;
    const bit_index = page_index % 8;
    const mask = @as(u8, 1) << @intCast(bit_index);
    return (bitmap[byte_index] & mask) != 0;
}

/// Allocate a single 4 KiB frame.
/// Returns the physical address or null if out of memory.
pub fn allocFrame() ?usize {
    const page_index = findFirstFree() orelse return null;

    markUsed(page_index);
    return page_index * PAGE_SIZE;
}

/// Free a previously allocated frame.
pub fn freeFrame(phys_addr: usize) void {
    const page_index = phys_addr / PAGE_SIZE;

    if (page_index >= total_pages) {
        @panic("Attempted to free invalid frame");
    }

    markFree(page_index);
}
