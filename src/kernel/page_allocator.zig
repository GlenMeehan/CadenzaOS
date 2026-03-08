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
    dummy: u8 = 0,

    pub fn init() PageAllocator {
        return .{};
    }

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

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        _ = ctx;
        _ = ret_addr;
        const align_log2 = @intFromEnum(alignment);
        if (align_log2 > 12) return null;
        const frames_needed = (len + 4095) / 4096;
        if (frames_needed > 1) return null;
        const frame_addr = bm.allocFrame() orelse return null;
        return @ptrFromInt(frame_addr);
    }

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
