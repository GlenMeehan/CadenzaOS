//src/kernel/fs/coda_sm.zig

const std = @import("std");
const mem = std.mem;
const BlockDevice = @import("block_device.zig").BlockDevice;
const vga = @import("../vga.zig");
const conv = @import("../convert.zig");
const memory = @import("../memory.zig");

const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

pub const SM_MAGIC: u64 = 0x434F44415F534D31; // "CODA_SM1"

pub const Extent = struct {
    start_block: u64, // inclusive LBA
    block_count: u64, // number of blocks in this extent
};

pub const SmHeader = struct {
    magic: u64,              // "CODA_SM1"
    free_extent_count: u32,
    reserved: [52]u8,        // pad to 64 bytes
};

pub const SpaceManagerError = error{
    OutOfSpace,
    InvalidExtent,
    IoError,
};

pub const SpaceManager = struct {
    device: *BlockDevice,
    free_list: ArrayListUnmanaged(Extent),

    /// Initialise from a fresh device (e.g. during mkfs).
    /// TODO: mark everything free except reserved regions (superblock, etc.)
    pub fn initFresh(
        allocator: std.mem.Allocator,
        device: *BlockDevice,
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
                .items = slice[0..1],   // slice of length 1
                .capacity = 1,
            },
        };
    }

    /// Load existing space metadata from disk (e.g. during mount).
    /// TODO: real on-disk metadata format

    pub fn initFromDisk(
        allocator: std.mem.Allocator,
        device: *BlockDevice,
        start_block: u64,
    ) !SpaceManager {
        // 1. Read the header first to know how many extents we have
        var header: SmHeader = undefined;
        try readBlockStruct(device, start_block, &header, @sizeOf(SmHeader));

        if (header.magic != SM_MAGIC)
            return error.BadSpaceManagerMagic;

        // 2. Allocate the exact memory needed for the items
        const slice = try allocator.alloc(Extent, header.free_extent_count);
        errdefer allocator.free(slice);

        // 3. Calculate total bytes needed for extents AND total blocks on disk
        const total_bytes = header.free_extent_count * @sizeOf(Extent);
        const blocks_to_read = (total_bytes + device.block_size - 1) / device.block_size;

        // 4. Create a buffer that is a MULTIPLE of block_size to satisfy the disk
        // We use the already allocated slice, but we must ensure the read
        // doesn't overflow the slice if the block alignment adds extra bytes.
        const read_size = blocks_to_read * device.block_size;

        // SAFETY: If read_size > slice memory, we need a temporary
        // block-aligned buffer, or to allocate the slice slightly larger.
        var temp_buf = try allocator.alloc(u8, read_size);
        defer allocator.free(temp_buf);

        try device.readBlocks(device.ctx, start_block + 1, temp_buf);

        // 5. Copy only the valid data into our actual slice
        const byte_slice = mem.sliceAsBytes(slice);
        @memcpy(byte_slice, temp_buf[0..total_bytes]);

        return SpaceManager{
            .device = device,
            .free_list = .{
                .items = slice,
                .capacity = header.free_extent_count,
            },
        };
    }

    /// Allocate an extent with at least `min_blocks` blocks.
    /// TODO: better allocation strategy (best-fit, extent merging)
    pub fn allocate(self: *SpaceManager, min_blocks: u64) !Extent {
        for (self.free_list.items, 0..) |*ext, i| {
            if (ext.block_count >= min_blocks) {
                const out = Extent{
                    .start_block = ext.start_block,
                    .block_count = min_blocks,
                };

                // Shrink the free extent
                ext.start_block += min_blocks;
                ext.block_count -= min_blocks;

                // If it becomes empty, remove it
                if (ext.block_count == 0) {
                    _ = self.free_list.swapRemove(i);
                }

                return out;
            }
        }

        return error.OutOfSpace;
    }

    /// Write space-manager metadata to disk.
    /// TODO: support multi-block metadata
    pub fn flushToDisk(
        self: *SpaceManager,
        allocator: std.mem.Allocator,
        start_block: u64,
        block_count: u64,
    ) !void {
        _ = allocator;
        _ = block_count;

        const blkdev = self.device;

        // Block 0 of SM region = header
        var header = SmHeader{
            .magic = SM_MAGIC,
            .free_extent_count = @as(u32, @intCast(self.free_list.items.len)),
            .reserved = [_]u8{0} ** 52,
        };

        try writeBlockStruct(blkdev, start_block, &header, @sizeOf(SmHeader));

        // Next blocks = extents
        var buf: [4096]u8 = undefined; // TODO: use device.block_size
        var offset: usize = 0;

        for (self.free_list.items) |ext| {
            const src = @as([*]const u8, @ptrCast(&ext))[0..@sizeOf(Extent)];
            _ = memory.memcpy(buf[offset .. offset + src.len].ptr, src.ptr, src.len);
            offset += src.len;
        }

        try blkdev.writeBlocks(blkdev.ctx, start_block + 1, buf[0..]);
    }

    /// Free a previously allocated extent.
    pub fn free(self: *SpaceManager, allocator: std.mem.Allocator, extent: Extent) !void {
        if (extent.block_count == 0) return;

        // For now, we just append the freed extent to our list.
        // We use the 'allocator' because the free_list might need to grow
        // its capacity to store the new extent.
        try self.free_list.append(allocator, extent);

        // Optional: In the future, you could call a sort/merge function here
        // to keep the free_list from getting too fragmented.
    }

    /// Optional: try to grow an extent in place.
    /// TODO: check if next free extent is adjacent
    pub fn tryGrow(
        self: *SpaceManager,
        extent: Extent,
        extra_blocks: u64,
    ) SpaceManagerError!?Extent {
        _ = self;
        _ = extent;
        _ = extra_blocks;
        // TODO: implement growing an extent
        return null;
    }

    /// Optional: query total free space (for stats/debug).
    /// TODO: sum free_list items
    pub fn totalFreeBlocks(self: *SpaceManager) SpaceManagerError!u64 {
        _ = self;
        // TODO: compute total free blocks
        return 0;
    }
};

fn readBlockStruct(device: *BlockDevice, lba: u64, ptr: *anyopaque, size: usize) !void {
    var buf: [512]u8 = undefined;
    if (size > buf.len or size > device.block_size)
        return error.StructTooLarge;

    try device.readBlocks(device.ctx, lba, buf[0..size]);

    const dst = @as([*]u8, @ptrCast(ptr))[0..size];
    _ = memory.memcpy(dst.ptr, buf[0..size].ptr, size);
}

fn writeBlockStruct(device: *BlockDevice, lba: u64, ptr: *const anyopaque, size: usize) !void {
    var buf: [512]u8 = undefined;
    @memset(buf[0..], 0);

    const src = @as([*]const u8, @ptrCast(ptr))[0..size];
    _ = memory.memcpy(buf[0..size].ptr, src.ptr, size);

    try device.writeBlocks(device.ctx, lba, buf[0..device.block_size]);
}

fn breakpoint(msg: []const u8) void {
    vga.writeString(msg, 0, 0);
    while (true) asm volatile ("hlt");
}
