// src/kernel/fs/coda_sm.zig
//
// CODA Space Manager
// ------------------
// Tracks free disk extents for the CODA filesystem.
// Responsibilities:
//   • On-disk header and extent list serialisation
//   • Extent allocation (first-fit) and freeing
//   • Flush to / restore from disk
//
// The on-disk layout within the SM region is:
//   [sm_start_block + 0]  SmHeader  (magic, extent count)
//   [sm_start_block + 1]  Extent[]  (packed array of free extents)
//
// NOTE: Multi-block metadata and best-fit allocation are not yet implemented.

const std           = @import("std");
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const BlockDevice   = @import("block_device.zig").BlockDevice;
const conv          = @import("../convert.zig");
const memory        = @import("../memory.zig");
const vga           = @import("../vga.zig");
const conf = @import("../config.zig");

// --------------------------------
// On-disk constants and structures
// --------------------------------

pub const SM_MAGIC: u64 = 0x434F44415F534D31;  // "CODA_SM1"

/// A contiguous range of disk blocks.
/// Used both as a free-list entry and as a file extent descriptor.
///
/// start_block  — first LBA in the range (inclusive)
/// block_count  — number of consecutive blocks
pub const Extent = struct {
    start_block: u64,
    block_count: u64,
};

/// On-disk header written at the first block of the SM region.
/// Followed immediately (next block) by the packed Extent array.
///
/// Layout is fixed at 64 bytes; reserved[] provides forward-compatibility padding.
pub const SmHeader = struct {
    magic:             u64,      // Must equal SM_MAGIC
    free_extent_count: u32,      // Number of Extent entries that follow
    reserved:          [52]u8,   // Pad to 64 bytes; must remain zeroed
};

/// Errors specific to SpaceManager operations.
pub const SpaceManagerError = error{
    OutOfSpace,
    InvalidExtent,
    IoError,
};

// --------------------------------
// SpaceManager
// --------------------------------

pub const SpaceManager = struct {
    device:    *BlockDevice,
    free_list: ArrayListUnmanaged(Extent),

    // ----------------------------------------------------------------
    // Initialisation
    // ----------------------------------------------------------------

    /// Initialise a fresh SpaceManager for a newly formatted device.
    /// Registers a single free extent covering [start_block, start_block + block_count).
    ///
    /// TODO: mark reserved regions (superblock, SM blocks) as already used.
    pub fn initFresh(
        allocator:   std.mem.Allocator,
        device:      *BlockDevice,
        start_block: u64,
        block_count: u64,
    ) !SpaceManager {
        const slice = try allocator.alloc(Extent, 1);
        slice[0] = .{
            .start_block = start_block,
            .block_count = block_count,
        };

        return SpaceManager{
            .device = device,
            .free_list = .{
                .items    = slice[0..1],
                .capacity = 1,
            },
        };
    }

    /// Load SpaceManager state from disk (e.g. during mount).
    /// Reads the SmHeader from `start_block`, then loads the Extent array
    /// from the following block(s).
    ///
    /// TODO: real multi-block on-disk metadata format.
    pub fn initFromDisk(
        allocator:   std.mem.Allocator,
        device:      *BlockDevice,
        start_block: u64,
    ) !SpaceManager {
        // 1. Read the first sector into an aligned buffer and extract the header
        var sector_buf: [conf.BLOCK_SIZE]u8 align(@alignOf(SmHeader)) = undefined;
        try device.readBlocks(device.ctx, start_block, &sector_buf);
        const header = @as(*const SmHeader, @ptrCast(&sector_buf)).*;

        if (header.magic != SM_MAGIC) return error.BadSpaceManagerMagic;

        // 2. Allocate the extent slice
        const slice = try allocator.alloc(Extent, header.free_extent_count);
        errdefer allocator.free(slice);

        // 3. Calculate how many full blocks cover all extents
        const total_bytes   = header.free_extent_count * @sizeOf(Extent);
        const blocks_to_read = (total_bytes + device.block_size - 1) / device.block_size;
        const read_size     = blocks_to_read * device.block_size;

        // 4. Read extent data from the block immediately following the header
        var temp_buf = try allocator.alloc(u8, read_size);
        defer allocator.free(temp_buf);
        try device.readBlocks(device.ctx, start_block + 1, temp_buf);

        // 5. Copy valid extent bytes into the final slice
        @memcpy(std.mem.sliceAsBytes(slice), temp_buf[0..total_bytes]);

        return SpaceManager{
            .device = device,
            .free_list = .{
                .items    = slice,
                .capacity = header.free_extent_count,
            },
        };
    }

    // ----------------------------------------------------------------
    // Allocation and freeing
    // ----------------------------------------------------------------

    /// Allocate an extent of exactly `min_blocks` blocks (first-fit).
    /// Shrinks the matched free extent in place; removes it if exhausted.
    /// Returns the allocated Extent.
    ///
    /// TODO: better strategy (best-fit, extent merging, coalescing).
    pub fn allocate(self: *SpaceManager, min_blocks: u64) !Extent {
        for (self.free_list.items, 0..) |*ext, i| {
            if (ext.block_count >= min_blocks) {
                const out = Extent{
                    .start_block = ext.start_block,
                    .block_count = min_blocks,
                };

                ext.start_block += min_blocks;
                ext.block_count -= min_blocks;

                if (ext.block_count == 0) {
                    _ = self.free_list.swapRemove(i);
                }

                return out;
            }
        }

        return error.OutOfSpace;
    }

    /// Return a previously allocated extent to the free list.
    /// The allocator may be used if the free_list needs to grow its backing store.
    ///
    /// TODO: coalesce adjacent free extents to reduce fragmentation.
    pub fn free(self: *SpaceManager, allocator: std.mem.Allocator, extent: Extent) !void {
        if (extent.block_count == 0) return;
        try self.free_list.append(allocator, extent);
    }

    // ----------------------------------------------------------------
    // Persistence
    // ----------------------------------------------------------------

    /// Serialise SpaceManager state to disk.
    ///   Block sm_start_block + 0  → SmHeader
    ///   Block sm_start_block + 1  → packed Extent array
    ///
    /// TODO: support extent lists that span more than one data block.
    pub fn flushToDisk(
        self:        *SpaceManager,
        allocator:   std.mem.Allocator,
        start_block: u64,
        block_count: u64,
    ) !void {
        _ = allocator;
        _ = block_count;

        const blkdev = self.device;

        // Write the header to the first SM block
        var header = SmHeader{
            .magic             = SM_MAGIC,
            .free_extent_count = @as(u32, @intCast(self.free_list.items.len)),
            .reserved          = [_]u8{0} ** 52,
        };
        try writeBlockStruct(blkdev, start_block, &header, @sizeOf(SmHeader));

        // Pack all extents into a buffer and write to the following block
        var buf: [4096]u8 = undefined;  // TODO: derive from device.block_size
        var offset: usize = 0;

        for (self.free_list.items) |ext| {
            const src = @as([*]const u8, @ptrCast(&ext))[0..@sizeOf(Extent)];
            _ = memory.memcpy(buf[offset .. offset + src.len].ptr, src.ptr, src.len);
            offset += src.len;
        }

        try blkdev.writeBlocks(blkdev.ctx, start_block + 1, buf[0..]);
    }

    // ----------------------------------------------------------------
    // Optional / future operations
    // ----------------------------------------------------------------

    /// Attempt to grow an existing extent in place by `extra_blocks`.
    /// Returns the grown Extent, or null if the adjacent space is not free.
    ///
    /// TODO: check whether the next free extent is adjacent.
    pub fn tryGrow(
        self:         *SpaceManager,
        extent:       Extent,
        extra_blocks: u64,
    ) SpaceManagerError!?Extent {
        _ = self;
        _ = extent;
        _ = extra_blocks;
        return null;
    }

    /// Return the total number of free blocks across all extents.
    ///
    /// TODO: sum free_list items.
    pub fn totalFreeBlocks(self: *SpaceManager) SpaceManagerError!u64 {
        _ = self;
        return 0;
    }
};

// ----------------------------------------------------------------
// File-private helpers
// ----------------------------------------------------------------

/// Serialise a struct into a zeroed 512-byte buffer and write it to `lba`.
fn writeBlockStruct(device: *BlockDevice, lba: u64, ptr: *const anyopaque, size: usize) !void {
    var buf: [conf.BLOCK_SIZE]u8 = undefined;
    @memset(buf[0..], 0);

    const src = @as([*]const u8, @ptrCast(ptr))[0..size];
    _ = memory.memcpy(buf[0..size].ptr, src.ptr, size);

    try device.writeBlocks(device.ctx, lba, buf[0..device.block_size]);
}

/// Halt the CPU and display a debug message.
/// Intended as a kernel-level breakpoint for development only.
fn breakpoint(msg: []const u8) void {
    vga.writeString(msg, 0, 0);
    while (true) asm volatile ("hlt");
}
