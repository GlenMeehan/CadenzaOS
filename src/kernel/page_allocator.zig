// src/kernel/page_allocator.zig
//
// This module wraps the physical frame allocator (bitmap.zig)
// in a std.mem.Allocator interface so that Zig's standard library
// containers (ArrayList, HashMap, etc.) can be used inside the kernel.
//
// Important notes:
//   • This allocator only supports *single 4 KiB pages*
//   • No multi‑page allocations
//   • No resizing or remapping
//   • Alignment > 4096 is rejected
//
// Higher‑level allocators (bump, slab, buddy) will eventually sit
// on top of this to provide general‑purpose heap allocation.

const std = @import("std");
const mem = std.mem;
const bm = @import("bitmap.zig");

pub const PageAllocator = struct {
    // Dummy field because Zig does not allow zero‑sized structs
    dummy: u8 = 0,

    /// Create a new PageAllocator instance.
    pub fn init() PageAllocator {
        return .{};
    }

    /// Return a std.mem.Allocator that uses this PageAllocator.
    pub fn allocator(self: *PageAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = remap,
            },
        };
    }

    /// Allocate memory using a single physical frame.
    ///
    /// Rules:
    ///   • Only 1 frame (4096 bytes) supported
    ///   • Alignment must be <= 4096
    ///   • Returns a raw pointer into physical memory
    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        _ = ctx;
        _ = ret_addr;

        // Reject alignments larger than a page
        const align_log2 = @intFromEnum(alignment);
        if (align_log2 > 12) return null; // > 4096 bytes

        // Only single‑page allocations supported
        const frames_needed = (len + 4095) / 4096;
        if (frames_needed > 1) return null;

        // Allocate a physical frame
        const frame_addr = bm.allocFrame() orelse return null;

        // Convert physical address to pointer
        return @ptrFromInt(frame_addr);
    }

    /// Resizing is not supported for page‑based allocation.
    fn resize(
        ctx: *anyopaque,
        buf: []u8,
        alignment: mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        _ = ctx;
        _ = buf;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return false;
    }

    /// Free a previously allocated frame.
    fn free(
        ctx: *anyopaque,
        buf: []u8,
        alignment: mem.Alignment,
        ret_addr: usize,
    ) void {
        _ = ctx;
        _ = alignment;
        _ = ret_addr;

        // Convert pointer back to physical address
        bm.freeFrame(@intFromPtr(buf.ptr));
    }

    /// Remapping is not supported (required for realloc‑like behaviour).
    fn remap(
        ctx: *anyopaque,
        buf: []u8,
        alignment: mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        _ = ctx;
        _ = buf;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;

        return null;
    }
};
