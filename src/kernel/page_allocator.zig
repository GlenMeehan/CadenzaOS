// src/kernel/page_allocator.zig
//
// A thin wrapper around the physical frame allocator (bitmap.zig)
// that exposes a `std.mem.Allocator` interface.
//
// Characteristics:
//   • Allocates exactly one 4 KiB physical page per allocation
//   • No multi‑page allocations
//   • No resizing, no remapping
//   • Alignment > 4096 is rejected
//
// Higher‑level allocators (bump, slab, buddy) can be layered on top.

const std = @import("std");
const mem = std.mem;
const bm = @import("bitmap.zig");

pub const PageAllocator = struct {
    dummy: u8 = 0, // placeholder; allocator stores no state

    /// Create a new PageAllocator instance.
    pub fn init() PageAllocator {
        return .{};
    }

    /// Return a std.mem.Allocator interface backed by this PageAllocator.
    pub fn allocator(self: *PageAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc  = alloc,
                .resize = resize,
                .free   = free,
                .remap  = remap,
            },
        };
    }

    // -------------------------------------------------------------------------
    //  ALLOC
    // -------------------------------------------------------------------------
    /// Allocate a single 4 KiB page.
    /// Returns null if:
    ///   • alignment > 4096
    ///   • requested length > 4096
    ///   • no free frames remain
    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        _ = ctx;
        _ = ret_addr;

        const align_log2 = @intFromEnum(alignment);
        if (align_log2 > 12) return null; // > 4096 alignment not supported

        const frames_needed = (len + 4095) / 4096;
        if (frames_needed > 1) return null; // only single‑page allocations allowed

        const frame_addr = bm.allocFrame() orelse return null;
        return @ptrFromInt(frame_addr);
    }

    // -------------------------------------------------------------------------
    //  RESIZE
    // -------------------------------------------------------------------------
    /// Resizing is not supported. Always returns false.
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

    // -------------------------------------------------------------------------
    //  FREE
    // -------------------------------------------------------------------------
    /// Free a previously allocated 4 KiB page.
    fn free(
        ctx: *anyopaque,
        buf: []u8,
        alignment: mem.Alignment,
        ret_addr: usize,
    ) void {
        _ = ctx;
        _ = alignment;
        _ = ret_addr;

        // buf.ptr is the physical address of the frame
        bm.freeFrame(@intFromPtr(buf.ptr));
    }

    // -------------------------------------------------------------------------
    //  REMAP
    // -------------------------------------------------------------------------
    /// Remapping is not supported. Always returns null.
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
