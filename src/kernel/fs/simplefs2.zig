// src/kernel/fs/simplefs.zig

// SimpleFS — a minimal block‑based filesystem for Cadenza OS.
// // On‑disk layout (all blocks are 512 bytes):
// Block 0: Superblock (packed struct)
// Block 1: Free‑space bitmap (1 bit per block)
// Block 2: Root directory (array of DirEntry)
// Blocks 3+: File data blocks
//
// Directory entries are tightly packed and fixed‑size.
// Filenames are zero‑terminated, max 31 chars.
// start_block = 0 means "no data allocated yet".
//
// This module performs no dynamic allocation and assumes a single root directory.

const mem = @import("../memory.zig");
const fs_block = @import("block_device.zig");
const BlockDevice = fs_block.BlockDevice;
const RamDisk = @import("ramdisk.zig").RamDisk;
const std = @import("std");
const mem2 = std.mem;
const vga = @import("../vga.zig");
const conv = @import("../convert.zig");

pub const Superblock = packed struct {
    // Packed to ensure exact on‑disk layout.
    // Size: 20 bytes.
    magic: u32,          // "CODA"
    version: u16,
    block_size: u16,
    total_blocks: u32,
    bitmap_start: u32,
    bitmap_blocks: u32,
    root_dir_block: u32,
    block_count: u32,
    free_map_block: u32,
};

pub const FsInfo = struct {
    block_size: u32,
    total_blocks: u32,
    total_bytes: u64,
    bitmap_blocks: u32,
    root_dir_block: u32,
};


pub const DirEntry = extern struct {
    // extern ensures C‑style layout.
    // Size: 32 + 4 + 4 + 4 = 44 bytes.
    // Alignment: 4 bytes.
    name: [32]u8,        // zero-terminated
    start_block: u32,
    block_count: u32,
    size_bytes: u32,
};

fn entryNameSlice(e: *align(1) const DirEntry) []const u8 {

    const full = e.name[0..];
    const zero_index = mem2.indexOfScalar(u8, full, 0) orelse full.len;
    return full[0..zero_index];
}

pub const SimpleFS = struct {
    device: *BlockDevice,
    backend: *RamDisk,

    // Format the filesystem:
    // - Write superblock to block 0
    // - Initialize bitmap (block 1)
    // - Zero the root directory block (block 2)
    pub fn mkfs(self: *SimpleFS) !void {
        const dev = self.device;

        // --- 1. Superblock ---
        var sb = Superblock{
            .magic = 0x434F4441, // "CODA"
            .version = 1,
            .block_size = @intCast(dev.block_size),
            .total_blocks = @intCast(dev.total_blocks),
            .bitmap_start = 1,
            .bitmap_blocks = 1,
            .root_dir_block = 2,
            .block_count = 10,
            .free_map_block = 1,
        };

        // Write superblock to block 0
        var sb_bytes: [@sizeOf(Superblock)]u8 = undefined;

        // Convert struct to raw pointers for memcpy
        const sb_src: [*]const u8 = @ptrCast(&sb);
        const sb_dst: [*]u8 = @ptrCast(&sb_bytes);

        // Copy bytes into the temporary buffer
        _ = mem.memcpy(sb_dst, sb_src, @sizeOf(Superblock));

        // Pad the rest of the block with zeros (we assume 512-byte blocks)
        var block0: [512]u8 = [_]u8{0} ** 512;
        // Copy the superblock bytes into the start of block0
        const block0_dst: [*]u8 = @ptrCast(&block0);
        const block0_src: [*]const u8 = @ptrCast(&sb_bytes);
        _ = mem.memcpy(block0_dst, block0_src, @sizeOf(Superblock));

        // Write block 0
        try self.backend.writeBlocksImpl(0, block0[0..]);

        // --- 2. Free-space bitmap ---
        // Mark blocks 0,1,2 as used
        var bitmap_block: [512]u8 = [_]u8{0} ** 512;
        bitmap_block[0] = 0b00000111; // first 3 blocks used
        try self.backend.writeBlocksImpl(1, bitmap_block[0..]);

        // --- 3. Empty root directory ---
        var root_dir_block: [512]u8 = [_]u8{0} ** 512;
        try self.backend.writeBlocksImpl(2, root_dir_block[0..]);
    }
    fn readBitmap(self: *SimpleFS, buf: *[512]u8) !void {
        var sb: Superblock = undefined;
        try self.readSuperblock(&sb);

        // For now we assume bitmap_blocks == 1 and block_size == 512.
        try self.backend.readBlocksImpl(sb.bitmap_start, buf[0..]);
    }

    fn writeBitmap(self: *SimpleFS, buf: *[512]u8) !void {
        var sb: Superblock = undefined;
        try self.readSuperblock(&sb);

        try self.backend.writeBlocksImpl(sb.bitmap_start, buf[0..]);
    }

    pub fn allocBlock(self: *SimpleFS) !u32 {
        var sb: Superblock = undefined;
        try self.readSuperblock(&sb);

        var bitmap: [512]u8 = undefined;
        try self.readBitmap(&bitmap);

        const total_blocks: u32 = sb.total_blocks;

        // Scan bytes
        var byte_index: usize = 0;
        while (byte_index < bitmap.len) : (byte_index += 1) {
            const byte = bitmap[byte_index];

            // 0xFF means all 8 bits are used
            if (byte == 0xFF) continue;

            // Scan bits in this byte
            var bit_index: usize = 0;
            while (bit_index < 8) : (bit_index += 1) {
                const mask: u8 = @as(u8, 1) << @intCast(bit_index);

                if ((byte & mask) == 0) {
                    const block_num: u32 = @intCast(byte_index * 8 + bit_index);

                    // Skip reserved blocks 0,1,2
                    if (block_num < 3) continue;

                    // Don’t allocate beyond total_blocks
                    if (block_num >= total_blocks) break;

                    // Mark bit as used
                    bitmap[byte_index] = byte | mask;
                    try self.writeBitmap(&bitmap);

                    return block_num;
                }
            }
        }

        return error.NoSpaceLeft;
    }

    // Superblock is packed, so memcpy is safe.
    // No alignment requirements.
    pub fn readSuperblock(self: *SimpleFS, out: *Superblock) !void {
        var block: [512]u8 = undefined;
        try self.backend.readBlocksImpl(0, block[0..]);

        // Copy bytes into the output struct safely
        const src: [*]const u8 = &block;
        const dst: [*]u8 = @ptrCast(out);

        _ = mem.memcpy(dst, src, @sizeOf(Superblock));
    }

    pub fn writeFileBlock(self: *SimpleFS, entry: *DirEntry, data: []const u8) !void {
        // Only supports 1-block files for now
        if (entry.block_count != 1) return error.NotSupported;

        var sb: Superblock = undefined;
        try self.readSuperblock(&sb);

        const block_size = sb.block_size;

        // Prepare a full block buffer
        var buf: [512]u8 = [_]u8{0} ** 512;

        const n = if (data.len > block_size) block_size else data.len;
        _ = mem.memcpy(
            @ptrCast(buf[0..n].ptr),
                       @ptrCast(data[0..n].ptr),
                       n,
        );

        try self.backend.writeBlocksImpl(entry.start_block, buf[0..]);

        entry.size_bytes = @intCast(n);
    }

    pub fn freeBlock(self: *SimpleFS, block_index: u32) !void {
        var sb: Superblock = undefined;
        try self.readSuperblock(&sb);

        // Bounds check
        if (block_index >= sb.total_blocks) {
            return error.BlockOutOfRange;
        }

        const bits_per_block = sb.block_size * 8;
        const bitmap_start = sb.bitmap_start;
        const bitmap_blocks = sb.bitmap_blocks;

        // Determine which bitmap block contains this bit
        const bitmap_block_index = block_index / bits_per_block;
        if (bitmap_block_index >= bitmap_blocks) {
            return error.BitmapTooSmall;
        }

        const block_offset = block_index % bits_per_block;
        const byte_index = block_offset / 8;
        const bit_index: u3 = @intCast(block_offset % 8);

        // Load the bitmap block
        var buf: [512]u8 = undefined;
        try self.backend.readBlocksImpl(bitmap_start + bitmap_block_index, buf[0..]);

        // Clear the bit
        buf[byte_index] &= ~(@as(u8, 1) << bit_index);

        // Write it back
        try self.backend.writeBlocksImpl(bitmap_start + bitmap_block_index, buf[0..]);
    }

    pub fn deleteFile(self: *SimpleFS, name: []const u8) !void {

        var sb: Superblock = undefined;
        try self.readSuperblock(&sb);

        // Load directory block
        var dir_block: [512]u8 align(@alignOf(DirEntry)) = undefined;
        try self.backend.readBlocksImpl(sb.root_dir_block, dir_block[0..]);

        // How many entries fit?
        const entry_count = @divFloor(512, @sizeOf(DirEntry));
        // Reinterpret safely
        const dir_bytes = dir_block[0 .. entry_count * @sizeOf(DirEntry)];
        const dir_entries = mem2.bytesAsSlice(DirEntry, dir_bytes);

        // Find the entry
        var found: ?usize = null;
        for (dir_entries, 0..) |*entry, i| {
            const entry_name = entryNameSlice(entry);
            if (entry_name.len == 0) continue; // free slot

            if (mem2.eql(u8, entry_name, name)) {
                found = i;
                break;
            }
        }


        if (found == null) return error.FileNotFound;

        const idx = found.?;
        var entry = &dir_entries[idx];

        // Free the block (single-block for now)
        if (entry.start_block != 0) {
            try self.freeBlock(entry.start_block);
        }

        // Clear entry
        entry.name[0] = 0;
        entry.start_block = 0;
        entry.block_count = 0;
        entry.size_bytes = 0;

        // Write directory back
        try self.backend.writeBlocksImpl(sb.root_dir_block, dir_block[0..]);
    }

};



// Extracts high‑level filesystem info for debugging and shell commands.
pub fn getInfo(self: *SimpleFS, info: *FsInfo) !void {
    var sb: Superblock = undefined;
    try self.readSuperblock(&sb);

    info.block_size = sb.block_size;
    info.total_blocks = sb.total_blocks;
    info.total_bytes =
    @as(u64, sb.block_size) * @as(u64, sb.total_blocks);
    info.bitmap_blocks = sb.bitmap_blocks;
    info.root_dir_block = sb.root_dir_block;
}

// Create a new empty file in the root directory.
// Does not allocate data blocks yet.
// Fails if the directory is full or the name is too long.
pub fn createFile(self: *SimpleFS, name: []const u8) !void {
    // 1. Read superblock
        var sb: Superblock = undefined;
        try self.readSuperblock(&sb);

    // Promote block_size (u16) to usize for arithmetic
    const block_size: usize = sb.block_size;

    // 2. Read root directory block
    // Directory block is a raw 512‑byte region containing tightly packed DirEntry structs.
    var dir_block: [512]u8 align(@alignOf(DirEntry)) = undefined;
    try self.backend.readBlocksImpl(sb.root_dir_block, dir_block[0..]);

    // Number of entries that fit in one directory block.
    // For 512‑byte blocks and 44‑byte entries, this is 11.
    const entry_count = block_size / @sizeOf(DirEntry);
    const entry_ptr: [*]DirEntry = @ptrCast(&dir_block);
    var entries = entry_ptr[0..entry_count];

    // 3. Find an empty entry (name[0] == 0)
    var free_index: ?usize = null;
    for (entries, 0..) |e, i| {
        if (e.name[0] == 0) {
            free_index = i;
            break;
        }
    }

    if (free_index == null) {
        return error.DirectoryFull;
    }

    const idx = free_index.?;

    // 4. Write the new entry
    var entry = &entries[idx];

    // Clear the entry
    const entry_bytes: *[@sizeOf(DirEntry)]u8 = @ptrCast(entry);
    @memset(entry_bytes, 0);

    // Copy name (truncate if needed)
    const max = entry.name.len - 1;
    const n = if (name.len > max) max else name.len;
    _ = mem.memcpy(
        @ptrCast(entry.name[0..n].ptr),
                   @ptrCast(name[0..n].ptr),
                   n,
    );
    entry.name[n] = 0; // zero-terminate

    const data_block = try self.allocBlock();

    entry.start_block = data_block;
    entry.block_count = 1;
    entry.size_bytes = 0;


    // 5. Write the directory block back to disk
    try self.backend.writeBlocksImpl(sb.root_dir_block, dir_block[0..]);
}

pub fn setBlockUsed(buf: []u8, block_index: u32) void {
    const idx: usize = @intCast(block_index / 8);
    const bit: u3 = @intCast(block_index % 8);
    buf[idx] |= @as(u8, 1) << bit;
}

pub fn setBlockFree(buf: []u8, block_index: u32) void {
    const idx: usize = @intCast(block_index / 8);
    const bit: u3 = @intCast(block_index % 8);
    buf[idx] &= ~(@as(u8, 1) << bit);
}

pub fn isBlockUsed(buf: []u8, block_index: u32) bool {
    const idx: usize = @intCast(block_index / 8);
    const bit: u3 = @intCast(block_index % 8);
    return (buf[idx] & (@as(u8, 1) << bit)) != 0;
}
