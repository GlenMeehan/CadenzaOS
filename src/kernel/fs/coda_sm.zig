// src/kernel/fs/coda_sm.zig
//
// CODA Space Manager
// ------------------
// Tracks free disk extents for the CODA filesystem.
//
// Responsibilities:
//   • On-disk header and free-extent serialisation
//   • Extent allocation (first-fit) and freeing
//   • Persisting allocator state to disk
//   • Restoring allocator state during filesystem mount
//
// The on-disk layout within the Space Manager region is:
//
//   [sm_start_block + 0]  SmHeader
//   [sm_start_block + 1]  Extent[] (packed array of free extents)
//
// NOTE:
//   Multi-block metadata structures and more advanced allocation
//   strategies (best-fit, coalescing policies, etc.) are not yet
//   implemented.

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

/// A contiguous range of filesystem blocks.
///
/// Used both:
///   • as an entry in the free-space list
///   • as a file-data extent recorded in FileMeta
///
/// start_block — first block in the range (inclusive)
/// block_count — number of contiguous blocks in the range
pub const Extent = extern struct {
    start_block: u64,
    block_count: u64,
};

/// On-disk header stored in the first block of the Space Manager region.
///
/// The header is followed by a packed array of Extent records beginning
/// in the next block.
///
/// Layout is fixed at 64 bytes. The reserved field provides space for
/// future format extensions while preserving on-disk compatibility.
pub const SmHeader = struct {
    magic:             u64,      // Must equal SM_MAGIC
    free_extent_count: u32,      // Number of free Extent records on disk
    reserved:          [52]u8,   // Reserved for future use; must remain zeroed
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

    /// Initialise a new SpaceManager for a freshly formatted filesystem.
    ///
    /// Creates a single free extent covering:
    ///
    ///     [start_block, start_block + block_count)
    ///
    /// TODO: Explicitly reserve filesystem metadata regions
    /// (superblock, SM blocks, etc.) rather than relying on callers
    /// to exclude them from the initial extent.
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

    /// Restore SpaceManager state from disk.
    ///
    /// Reads the Space Manager header from `start_block`, validates it,
    /// then loads the persisted free-extent list from the following block(s).
    ///
    /// TODO: Support a richer on-disk metadata format spanning multiple
    /// metadata records or regions.
    pub fn initFromDisk(
        allocator:   std.mem.Allocator,
        device:      *BlockDevice,
        start_block: u64,
    ) !SpaceManager {

        // 1. Read the Space Manager header block into an aligned buffer.
        var sector_buf: [conf.BLOCK_SIZE]u8 align(@alignOf(SmHeader)) = undefined;

        try device.readBlocks(device.ctx, start_block, &sector_buf);

        const header = @as(*const SmHeader, @ptrCast(&sector_buf)).*;

        // Validate that the on-disk structure is recognisably a
        // Space Manager region before attempting to continue.
        if (header.magic != SM_MAGIC)
            return error.BadSpaceManagerMagic;

        // 2. Allocate storage for all free extents described by
        //    the header.
        const slice = try allocator.alloc(Extent, header.free_extent_count);
        errdefer allocator.free(slice);

        // 3. Calculate how many complete blocks are required to hold
        //    the persisted extent array.
        const total_bytes    = header.free_extent_count * @sizeOf(Extent);
        const blocks_to_read = (total_bytes + device.block_size - 1) / device.block_size;
        const read_size      = blocks_to_read * device.block_size;

        // 4. Read the packed extent data immediately following the header.
        var temp_buf = try allocator.alloc(u8, read_size);
        defer allocator.free(temp_buf);

        try device.readBlocks(device.ctx, start_block + 1, temp_buf);

        // 5. Copy only the valid extent bytes into the final extent array.
        //    Any trailing padding bytes in the temporary buffer are ignored.
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

    /// Allocate an extent containing exactly `min_blocks` blocks.
    ///
    /// Uses a simple first-fit strategy:
    ///   • the first sufficiently large free extent is selected
    ///   • the allocation is carved from the beginning of that extent
    ///   • the remaining free extent is shrunk in place
    ///
    /// If the allocation consumes the entire extent, the free-list
    /// entry is removed.
    ///
    /// TODO: Implement improved allocation policies such as best-fit,
    /// extent coalescing, and fragmentation-aware placement.
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
    ///
    /// The allocator may be used to grow the backing storage of the
    /// free-list if additional capacity is required.
    ///
    /// NOTE:
    ///   This implementation simply appends the extent. Adjacent free
    ///   extents are not currently merged, which can lead to
    ///   fragmentation over time.
    ///
    /// TODO: Coalesce neighbouring free extents.
    pub fn free(self: *SpaceManager, allocator: std.mem.Allocator, extent: Extent) !void {
        if (extent.block_count == 0) return;

        try self.free_list.append(allocator, extent);
    }

    // ----------------------------------------------------------------
    // Persistence
    // ----------------------------------------------------------------

    /// Persist the current Space Manager state to disk.
    ///
    /// On-disk layout:
    ///   Block start_block + 0  -> SmHeader
    ///   Block start_block + 1  -> packed Extent array
    ///
    /// The free-list is serialised as a contiguous sequence of Extent
    /// structures immediately following the header block.
    ///
    /// TODO: Support extent lists that span multiple metadata blocks.
    pub fn flushToDisk(
        self:        *SpaceManager,
        allocator:   std.mem.Allocator,
        start_block: u64,
        block_count: u64,
    ) !void {
        _ = allocator;
        _ = block_count;

        const blkdev = self.device;

        // Write the Space Manager header block first.
        var header = SmHeader{
            .magic             = SM_MAGIC,
            .free_extent_count = @as(u32, @intCast(self.free_list.items.len)),
            .reserved          = [_]u8{0} ** 52,
        };

        try writeBlockStruct(
            blkdev,
            start_block,
            &header,
            @sizeOf(SmHeader),
        );

        // Pack all free extents into a temporary buffer before writing
        // them to the metadata block following the header.
        var buf: [4096]u8 = undefined; // TODO: derive from device.block_size

        @memset(&buf, 0);

        if (self.free_list.items.len * @sizeOf(Extent) > buf.len)
            return error.SpaceMapTooLarge;

        var offset: usize = 0;

        for (self.free_list.items) |ext| {
            const src = @as([*]const u8, @ptrCast(&ext))[0..@sizeOf(Extent)];

            _ = memory.memcpy(
                buf[offset .. offset + src.len].ptr,
                src.ptr,
                src.len,
            );

            offset += src.len;
        }

        try blkdev.writeBlocks(
            blkdev.ctx,
            start_block + 1,
            buf[0..],
        );
    }

    // ----------------------------------------------------------------
    // Optional / future operations
    // ----------------------------------------------------------------

    /// Attempt to grow an allocated extent in place.
    ///
    /// The intended implementation is to check whether free space
    /// immediately follows the supplied extent and, if so, extend it
    /// without relocating file data.
    ///
    /// Returns:
    ///   • Extent  -> successfully grown
    ///   • null    -> adjacent space unavailable
    ///
    /// TODO: Implement adjacency checks against the free-list.
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

    /// Return the total number of free blocks managed by the
    /// Space Manager.
    ///
    /// TODO: Implement using free_list aggregation or remove in favour
    /// of getFreeBlockCount().
    pub fn totalFreeBlocks(self: *SpaceManager) SpaceManagerError!u64 {
        _ = self;
        return 0;
    }

    /// Calculate the total number of blocks currently available for
    /// allocation across all free extents.
    pub fn getFreeBlockCount(self: *const SpaceManager) u64 {
        var free_total: u64 = 0;

        for (self.free_list.items) |ext| {
            free_total += ext.block_count;
        }

        return free_total;
    }

    /// Calculate the total number of blocks currently in use.
    ///
    /// This is derived from the supplied device capacity and the
    /// current free-space inventory.
    pub fn getUsedBlockCount(self: *const SpaceManager, total_disk_blocks: u64) u64 {
        return total_disk_blocks - self.getFreeBlockCount();
    }

};

// ----------------------------------------------------------------
// File-private helpers
// ----------------------------------------------------------------

/// Serialise a structure into a zero-filled block buffer and write it
/// to the specified on-disk block.
///
/// Any unused bytes in the destination block remain zeroed, ensuring
/// deterministic on-disk metadata records.
fn writeBlockStruct(
    device: *BlockDevice,
    lba: u64,
    ptr: *const anyopaque,
    size: usize,
) !void {
    var buf: [conf.BLOCK_SIZE]u8 = undefined;

    @memset(buf[0..], 0);

    const src = @as([*]const u8, @ptrCast(ptr))[0..size];

    _ = memory.memcpy(
        buf[0..size].ptr,
        src.ptr,
        size,
    );

    try device.writeBlocks(
        device.ctx,
        lba,
        buf[0..device.block_size],
    );
}

/// Halt execution and display a diagnostic message.
///
/// Intended solely as a kernel-development debugging aid and should
/// not be used for normal runtime error handling.
fn breakpoint(msg: []const u8) void {
    vga.writeString(msg, 0, 0);

    while (true)
        asm volatile ("hlt");
}
