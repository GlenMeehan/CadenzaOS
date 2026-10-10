// src/kernel/bitmap.zig
//
// Physical frame bitmap allocator.
//
// Tracks allocation state for 4 KiB physical pages using a bitmap:
//
//     0 = free
//     1 = allocated / reserved
//
// Responsibilities:
//   • Initialise allocator state from usable E820 memory regions
//   • Mark kernel, stack, heap, page tables, and other reserved areas
//   • Allocate and free individual 4 KiB frames
//
// Notes:
//   • All pages begin in the USED state and usable E820 pages are
//     subsequently marked FREE.
//   • Backed by a fixed 32 KiB bitmap, supporting up to ~1 GiB of RAM.
//   • Supports only single-page allocation.
//   • No contiguous allocation, merging, or fragmentation management.

const std   = @import("std");
const frame_allocator = @import("frame_allocator.zig");
const Region = frame_allocator.Region;
const vga   = @import("vga.zig");
const mem   = @import("memory.zig");

/// Size of a managed physical frame.
pub const PAGE_SIZE: usize = 4096;

// -----------------------------------------------------------------------------
//  GLOBAL BITMAP STORAGE
// -----------------------------------------------------------------------------

// 32,768 bytes -> 262,144 bits -> 262,144 pages -> 1 GiB of RAM.
//
// Bits are initialised to 1 so all memory starts in the reserved state
// until explicitly marked usable during initialisation.
var bitmap_storage: [32768]u8 = [_]u8{0xFF} ** 32768;

var bitmap: []u8 = bitmap_storage[0..];

/// Total number of pages discovered across all usable memory regions.
var total_pages: usize = 0;

// -----------------------------------------------------------------------------
//  INTERNAL HELPERS
// -----------------------------------------------------------------------------

/// Return the number of bitmap bytes required to represent `pages` pages.
fn computeBitmapSize(pages: usize) usize {
    return (pages + 7) / 8;
}

/// Mark a page as free (bit = 0).
fn markFree(page_index: usize) void {
    const byte_index = page_index / 8;
    const bit_index  = page_index % 8;

    bitmap[byte_index] &= ~(@as(u8, 1) << @intCast(bit_index));
}

/// Mark a page as allocated/reserved (bit = 1).
fn markUsed(page_index: usize) void {
    const byte_index = page_index / 8;
    const bit_index  = page_index % 8;

    bitmap[byte_index] |= (@as(u8, 1) << @intCast(bit_index));
}

// -----------------------------------------------------------------------------
//  INITIALISATION
// -----------------------------------------------------------------------------

/// Initialise the bitmap allocator from the supplied usable memory regions.
///
/// All pages start in the USED state. Each usable E820 region is then
/// converted into FREE bitmap entries, leaving reserved regions intact.
pub fn init(regions: []const Region) void {

    // 1. Count the total number of usable pages.
    var total: usize = 0;

    for (regions) |r| {
        total += r.length / PAGE_SIZE;
    }

    total_pages = total;

    // 2. Verify that the fixed bitmap is large enough to represent
    //    all discovered pages.
    const needed_bytes = computeBitmapSize(total_pages);

    if (needed_bytes > bitmap.len) {
        @panic("Bitmap storage too small for available memory");
    }

    // 3. Mark every page belonging to a usable memory region as free.
    for (regions) |r| {
        const start_page = r.base / PAGE_SIZE;
        const page_count = r.length / PAGE_SIZE;

        var i: usize = 0;

        while (i < page_count) : (i += 1) {
            markFree(start_page + i);
        }
    }
}

// -----------------------------------------------------------------------------
//  RANGE MARKING
// -----------------------------------------------------------------------------

/// Mark a physical address range as allocated/reserved.
///
/// `start_phys` is inclusive.
/// `end_phys` is exclusive.
pub fn markUsedRange(start_phys: usize, end_phys: usize) void {
    const start_page = start_phys / PAGE_SIZE;
    const end_page   = (end_phys + PAGE_SIZE - 1) / PAGE_SIZE;

    var page = start_page;
    while (page < end_page) : (page += 1) {
        markUsed(page);
    }
}

/// Return the physical memory range occupied by the bitmap itself.
///
/// The allocator must reserve this region to avoid allocating the
/// memory used to store its own bookkeeping structures.
pub fn getStorageRange() struct { start: usize, end: usize } {
    const virt_start = @intFromPtr(&bitmap_storage[0]);
    const virt_end   = virt_start + bitmap_storage.len;

    const phys_start = mem.virtToPhys(virt_start);
    const phys_end   = mem.virtToPhys(virt_end);

    return .{ .start = phys_start, .end = phys_end };
}

// -----------------------------------------------------------------------------
//  ALLOCATION
// -----------------------------------------------------------------------------

/// Find the first free page in the bitmap.
///
/// Returns the page index, or null if no free pages remain.
fn findFirstFree() ?usize {
    for (bitmap, 0..) |byte, byte_index| {
        if (byte == 0xFF) continue; // All 8 pages allocated

        // At least one page in this byte is free.
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

/// Return true if the specified page is currently marked used.
fn isUsed(page_index: usize) bool {
    const byte_index = page_index / 8;
    const bit_index  = page_index % 8;

    const mask = @as(u8, 1) << @intCast(bit_index);

    return (bitmap[byte_index] & mask) != 0;
}

/// Allocate a single 4 KiB physical frame.
///
/// Returns the frame's physical base address, or null if no free
/// frames are available.
pub fn allocFrame() ?usize {
    const page_index = findFirstFree() orelse return null;

    markUsed(page_index);

    return page_index * PAGE_SIZE;
}

/// Free a previously allocated 4 KiB frame.
pub fn freeFrame(phys_addr: usize) void {
    const page_index = phys_addr / PAGE_SIZE;

    if (page_index >= total_pages) {
        @panic("Attempted to free invalid frame");
    }

    markFree(page_index);
}

/// Find the first run of `count` consecutive free pages.
///
/// Returns the starting page index, or null if no sufficiently
/// large contiguous region exists.
fn findFirstFreeRun(count: usize) ?usize {
    if (count == 0) return null;

    var run_start: usize = 0;
    var run_len: usize = 0;
    var page_index: usize = 0;

    while (page_index < total_pages) : (page_index += 1) {
        if (!isUsed(page_index)) {
            if (run_len == 0) run_start = page_index;

            run_len += 1;

            if (run_len == count)
                return run_start;
        } else {
            run_len = 0;
        }
    }

    return null;
}

/// Allocate `count` consecutive 4 KiB frames as a single contiguous run.
///
/// Returns the physical base address of the first frame, or null if no
/// contiguous run of sufficient size exists.
///
/// Unlike repeated allocFrame() calls, this guarantees physical
/// contiguity by reserving the entire run as a single operation.
pub fn allocContiguous(count: usize) ?usize {
    const page_index = findFirstFreeRun(count) orelse return null;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        markUsed(page_index + i);
    }

    return page_index * PAGE_SIZE;
}

/// Free `count` contiguous frames beginning at `phys_addr`.
///
/// Counterpart to allocContiguous().
pub fn freeContiguous(phys_addr: usize, count: usize) void {
    const start_page = phys_addr / PAGE_SIZE;

    if (start_page + count > total_pages) {
        @panic("Attempted to free invalid contiguous frame range");
    }

    var i: usize = 0;
    while (i < count) : (i += 1) {
        markFree(start_page + i);
    }
}
