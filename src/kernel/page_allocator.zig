// src/kernel/page_allocator.zig
//
// A minimal std.mem.Allocator implementation backed by the physical
// frame allocator (bitmap.zig).
//
// Characteristics:
//   • Allocates a single 4 KiB frame per allocation
//   • No support for multi-page allocations
//   • No resizing of existing allocations
//   • No remapping support
//   • Alignments larger than 4 KiB are rejected
//
// This allocator is intended as a thin compatibility layer that allows
// physical frame allocation to be used through Zig's allocator APIs.
//
// Higher-level allocators (bump, slab, buddy, etc.) can be layered on
// top of this implementation.
//
const std = @import("std");
const mem = std.mem;
const bm = @import("bitmap.zig");

pub const PageAllocator = struct {

    /// Placeholder field.
    ///
    /// The allocator maintains no runtime state but requires a concrete
    /// instance so a std.mem.Allocator interface can reference it.
    dummy: u8 = 0,

    /// Create a new PageAllocator instance.
    pub fn init() PageAllocator {
        return .{};
    }

    /// Return a std.mem.Allocator interface backed by the physical
    /// frame allocator.
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
    //  ALLOCATION
    // -------------------------------------------------------------------------

    /// Allocate a single 4 KiB physical frame.
    ///
    /// Returns null if:
    ///   • The requested alignment exceeds 4 KiB
    ///   • More than one page would be required
    ///   • No free frames remain
    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        _ = ctx;
        _ = ret_addr;

        const align_log2 = @intFromEnum(alignment);

        // Alignments greater than a page are unsupported.
        if (align_log2 > 12) return null;

        const frames_needed = (len + 4095) / 4096;

        // This allocator only supports single-page allocations.
        if (frames_needed > 1) return null;

        const frame_addr = bm.allocFrame() orelse return null;

        return @ptrFromInt(frame_addr);
    }

    // -------------------------------------------------------------------------
    //  RESIZE
    // -------------------------------------------------------------------------

    /// Resizing is not supported by the underlying frame allocator.
    ///
    /// Always returns false.
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

    /// Return a previously allocated frame to the bitmap allocator.
    ///
    /// The allocation address corresponds directly to the physical
    /// frame returned by alloc().
    fn free(
        ctx: *anyopaque,
        buf: []u8,
        alignment: mem.Alignment,
        ret_addr: usize,
    ) void {
        _ = ctx;
        _ = alignment;
        _ = ret_addr;

        bm.freeFrame(@intFromPtr(buf.ptr));
    }

    // -------------------------------------------------------------------------
    //  REMAP
    // -------------------------------------------------------------------------

    /// Remapping is not supported.
    ///
    /// Always returns null.
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
