// src/kernel/fs/coda_fs.zig

const std = @import("std");
const BlockDevice = @import("block_device.zig").BlockDevice;
const SpaceManager = @import("coda_sm.zig").SpaceManager;
const Directory = @import("coda_file.zig").Directory;
const DirEntry = @import("coda_file.zig").DirEntry;
const FileMeta = @import("coda_file.zig").FileMeta;
const vga = @import("../vga.zig");
const conf = @import("../config.zig");
const Extent = @import("coda_sm.zig").Extent;
const memory = @import("../memory.zig");
const MAX_NAME = @import("coda_file.zig").MAX_NAME;

pub const CODA_MAGIC: u64 = 0x434F44415F465331;
pub const CODA_VERSION: u32 = 1;
pub const FLAG_DIRTY: u64 = 1 << 0; // Value: 0x0000000000000001




pub const Superblock = struct {
    magic: u64,
    flags: u64,
    version: u32,
    block_size: u32,
    total_blocks: u64,

    sm_start_block: u64,
    sm_block_count: u64,

    root_dir_extent_start: u64,
    root_dir_extent_blocks: u64,

    reserved: [64]u8,
};

pub const CodaFs = struct {
    device: *BlockDevice,
    superblock: Superblock,
    space_manager: SpaceManager,
    root_dir: Directory,
    // Searches the root directory for a filename and returns its metadata LBA
    pub fn findFile(fs: *CodaFs, allocator: std.mem.Allocator, name: []const u8) !u64 {
        // FIX: Allocate based on the actual number of blocks in the root directory
        const dir_size = fs.superblock.root_dir_extent_blocks * fs.device.block_size;
        const dir_buf = try allocator.alloc(u8, dir_size);
        defer allocator.free(dir_buf);

        // FIX: Read all blocks belonging to the root directory
        const root_lba = fs.superblock.root_dir_extent_start;
        try fs.device.readBlocks(fs.device.ctx, root_lba, dir_buf);

        // FIX: Map the entries across the entire multi-block buffer
        const entry_count = dir_size / @sizeOf(DirEntry);
        const entries = @as([*]DirEntry, @ptrCast(@alignCast(dir_buf.ptr)))[0..entry_count];

        for (entries) |entry| {
            if (entry.name_len == name.len) {
                if (std.mem.eql(u8, entry.name[0..entry.name_len], name)) {
                    return entry.meta_extent.start_block;
                }
            }
        }
        return error.FileNotFound;
    }

    // Loads the FileMeta struct from a specific disk block
    pub fn readFileMeta(fs: *CodaFs, allocator: std.mem.Allocator, meta_lba: u64) !FileMeta {
        // 1. Allocate a temporary buffer for one disk block
        const buf = try allocator.alloc(u8, fs.device.block_size);
        defer allocator.free(buf);

        // 2. Read the block from the device
        try fs.device.readBlocks(fs.device.ctx, meta_lba, buf);

        // 3. Cast the buffer bytes into our FileMeta struct
        // We use @ptrCast and @alignCast to tell Zig these bytes are a struct
        const meta_ptr = @as(*FileMeta, @ptrCast(@alignCast(buf.ptr)));

        // 4. Return a copy of the struct
        return meta_ptr.*;
    }
    pub fn appendBlockToFile(self: *CodaFs, allocator: std.mem.Allocator, meta_lba: u64, meta: *FileMeta) !u64 {
        _ = allocator;
        // 1. Ask SpaceManager for 1 new block
        const new_extent = try self.space_manager.allocate(1);

        // 2. Add this extent to the FileMeta's list
        if (meta.extent_count >= 8) return error.FileTooManyExtents; // Assuming a limit of 8 for now

        meta.extents[meta.extent_count] = new_extent;
        meta.extent_count += 1;

        // 3. Write the updated FileMeta back to the disk so it "remembers" the new block
        try self.writeBlockStruct(meta_lba, meta, @sizeOf(FileMeta));

        // Return the LBA of the newly allocated data block
        return new_extent.start_block;
    }

    pub fn writeBlockStruct(self: *CodaFs, lba: u64, ptr: *const anyopaque, size: usize) !void {
        var buf: [conf.BASE_IO_BUF_SIZE]u8 = undefined;
        @memset(buf[0..], 0);

        const src = @as([*]const u8, @ptrCast(ptr))[0..size];
        _ = memory.memcpy(buf[0..size].ptr, src.ptr, size);

        // Use self.device here
        try self.device.writeBlocks(self.device.ctx, lba, buf[0..self.device.block_size]);
    }

    pub fn mount(allocator: std.mem.Allocator, device: *BlockDevice) !CodaFs {
        // 1. Read Superblock from LBA 2048
        var sb: Superblock = undefined;
        try readSuperblock(device, 2048, &sb);

        // Basic validation
        if (sb.magic != CODA_MAGIC) return error.InvalidMagic;

        // 2. Initialize Space Manager from disk
        // We use the start block and count stored in the Superblock
        const sm = try SpaceManager.initFromDisk(
            allocator,
            device,
            sb.sm_start_block
        );

        // 3. Prepare the Root Directory
        // For now, we point to the extent. In a full VFS, we'd load the entries here.
        const root_dir = Directory{
            .entries = &[_]DirEntry{}, // We will implement a 'load' method next
        };

        return CodaFs{
            .device = device,
            .superblock = sb,
            .space_manager = sm,
            .root_dir = root_dir,
        };
    }

    pub fn mkfs(allocator: std.mem.Allocator, device: *BlockDevice) !void {
        if (device.block_size < conf.BASE_IO_BUF_SIZE) return error.InvalidBlockSize;

        const total_blocks = device.total_blocks;

        // --- THE SAFETY SHIFT ---
        const sb_block: u64 = 2048;
        const sm_start_block: u64 = 2049;
        const sm_block_count: u64 = 16;
        // ------------------------

        const data_start_block = sm_start_block + sm_block_count;
        if (data_start_block >= total_blocks) return error.TooSmall;

        // Space manager now starts tracking blocks FROM 2065 onwards
        var sm = try SpaceManager.initFresh(
            allocator,
            device,
            data_start_block,
            total_blocks - data_start_block,
        );
        // This will now correctly allocate block 2065 for your root dir
        const root_extent = try sm.allocate(4);

        var sb = Superblock{
            .magic = CODA_MAGIC,
            .version = CODA_VERSION,
            .block_size = @as(u32, @intCast(device.block_size)),
            .total_blocks = total_blocks,
            .sm_start_block = sm_start_block,
            .sm_block_count = sm_block_count,
            .root_dir_extent_start = root_extent.start_block,
            .root_dir_extent_blocks = root_extent.block_count,
            .flags = 0,
            .reserved = [_]u8{0} ** 64,
        };
        try sm.flushToDisk(allocator, sm_start_block, sm_block_count);
        try initEmptyRootDir(device, root_extent);
        try writeSuperblock(device, sb_block, &sb);
    }

    fn writeSuperblock(device: *BlockDevice, lba: u64, sb: *const Superblock) !void {
        var buf: [conf.BASE_IO_BUF_SIZE]u8 = undefined;
        @memset(buf[0..], 0);

        const src = @as([*]const u8, @ptrCast(sb))[0..@sizeOf(Superblock)];
        _ = memory.memcpy(buf[0..src.len].ptr, src.ptr, src.len);

        try device.writeBlocks(device.ctx, lba, buf[0..device.block_size]);
    }

    fn readSuperblock(device: *BlockDevice, lba: u64, sb: *Superblock) !void {
        var buf: [conf.BASE_IO_BUF_SIZE]u8 = undefined;
        try device.readBlocks(device.ctx, lba, buf[0..device.block_size]);

        const dst = @as([*]u8, @ptrCast(sb))[0..@sizeOf(Superblock)];
        _ = memory.memcpy(dst.ptr, buf[0..dst.len].ptr, dst.len);
    }

    pub fn readBlockStruct(device: *BlockDevice, lba: u64, ptr: *anyopaque, size: usize) !void {
        var buf: [conf.BASE_IO_BUF_SIZE]u8 = undefined;
        try device.readBlocks(device.ctx, lba, buf[0..device.block_size]);

        const dst = @as([*]u8, @ptrCast(ptr))[0..size];
        _ = memory.memcpy(dst.ptr, buf[0..size].ptr, size);
    }



    pub fn createFile(fs: *CodaFs, allocator: std.mem.Allocator, name: []const u8) !void {
        if (name.len > MAX_NAME) return error.NameTooLong;

        // 1. Check if the file already exists
        if (fs.findFile(allocator, name)) |_| {
            // If findFile succeeds, the file EXISTS. Stop here.
            vga.writeString("Error: File already exists\n", 12, 0);
            return error.AlreadyExists;
        } else |err| {
            // If findFile failed, we check WHY.
            // If it's anything OTHER than FileNotFound, it's a real disk error.
            if (err != error.FileNotFound) return err;

            // If it WAS FileNotFound, we just continue normally!
        }

        // 2. Allocate a block for the FileMeta (The header)
        const meta_extent = try fs.space_manager.allocate(1);

        // 3. Allocate a starting block for the actual DATA
        const data_extent = try fs.space_manager.allocate(1);

        // 4. Initialize FileMeta (Zero out the extents)
        var meta = FileMeta{
            .file_type = .File,
            .size_bytes = 0,
            .extent_count = 1,
            .extents = [_]Extent{.{ .start_block = 0, .block_count = 0 }} ** 8,
        };
        meta.extents[0] = data_extent;

        try fs.writeBlockStruct(meta_extent.start_block, &meta, @sizeOf(FileMeta));

        // --- THE FIX: Explicitly flush this specific meta block to the ATA device ---
        const meta_bytes = @as([*]const u8, @ptrCast(&meta))[0..@sizeOf(FileMeta)];
        try fs.device.writeBlocks(fs.device.ctx, meta_extent.start_block, meta_bytes);

        // 5. Load the ENTIRE root directory extent
        const dir_size = fs.superblock.root_dir_extent_blocks * fs.device.block_size;
        const dir_buf = try allocator.alloc(u8, dir_size);
        defer allocator.free(dir_buf);

        const root_lba = fs.superblock.root_dir_extent_start;
        try fs.device.readBlocks(fs.device.ctx, root_lba, dir_buf);

        const entry_count = dir_size / @sizeOf(DirEntry);
        const entries = @as([*]DirEntry, @ptrCast(@alignCast(dir_buf.ptr)))[0..entry_count];
        var dir = Directory{ .entries = entries };

        // 6. Create and add the new entry (Your existing logic is fine here)
        var new_entry = DirEntry{
            .name = [_]u8{0} ** MAX_NAME,
            .name_len = @as(u8, @intCast(name.len)),
            .meta_extent = meta_extent,
        };
        @memcpy(new_entry.name[0..name.len], name);

        try dir.addEntry(new_entry);

        // 7. Write the FULL directory back to disk
        try fs.device.writeBlocks(fs.device.ctx, root_lba, dir_buf);
        //try fs.space_manager.flushToDisk(allocator, fs.superblock.sm_start_block, fs.superblock.sm_block_count);
    }

    pub fn readFile(fs: *CodaFs, path: []const u8, out: []u8) !usize {
        _ = fs;
        _ = path;
        _ = out;
        return error.NotImplemented;
    }

    pub fn writeFile(fs: *CodaFs, path: []const u8, data: []const u8) !void {
        _ = fs;
        _ = path;
        _ = data;
        return error.NotImplemented;
    }

    pub fn deleteFile(self: *CodaFs, allocator: std.mem.Allocator, name: []const u8) !void {
        // 1. Find the file to get the metadata LBA
        const meta_lba = try self.findFile(allocator, name);

        // 2. Read the metadata to know which blocks to free
        var meta = try self.readFileMeta(allocator, meta_lba);

        // 3. Free all data extents
        for (meta.extents[0..meta.extent_count]) |extent| {
            // Pass the allocator down to the space manager
            try self.space_manager.free(allocator, extent);
        }

        // 4. Free the metadata block itself
        try self.space_manager.free(allocator, Extent{ .start_block = meta_lba, .block_count = 1 });

        // 5. Remove the entry from the directory
        const dir_buf = try allocator.alloc(u8, self.device.block_size);
        defer allocator.free(dir_buf);

        const root_lba = self.superblock.root_dir_extent_start;
        try self.device.readBlocks(self.device.ctx, root_lba, dir_buf);

        const entries = @as([*]DirEntry, @ptrCast(@alignCast(dir_buf.ptr)))[0 .. self.device.block_size / @sizeOf(DirEntry)];

        // Look for the entry and "zero it out"
        var found = false;
        for (entries) |*entry| {
            if (entry.name_len == name.len and std.mem.eql(u8, entry.name[0..name.len], name)) {
                // Found it! Clear the entry
                @memset(std.mem.asBytes(entry), 0);
                found = true;
                break;
            }
        }

        if (!found) return error.FileNotFound;

        // 6. Write changes back to disk
        try self.device.writeBlocks(self.device.ctx, root_lba, dir_buf);
        try self.space_manager.flushToDisk(allocator, self.superblock.sm_start_block, self.superblock.sm_block_count);
    }

    pub fn listDir(fs: *CodaFs, allocator: std.mem.Allocator, path: []const u8) ![]DirEntry {
        if (!std.mem.eql(u8, path, "/")) return error.PathNotFound;

        const dir_size = fs.superblock.root_dir_extent_blocks * fs.device.block_size;
        const buf = try allocator.alloc(u8, dir_size);
        defer allocator.free(buf);

        try fs.device.readBlocks(fs.device.ctx, fs.superblock.root_dir_extent_start, buf);

        const entry_count = dir_size / @sizeOf(DirEntry);
        const entries = @as([*]DirEntry, @ptrCast(@alignCast(buf.ptr)))[0..entry_count];

        // Count valid entries across all blocks
        var valid_count: usize = 0;
        for (entries) |entry| {
            if (entry.name_len > 0) valid_count += 1;
        }

        const results = try allocator.alloc(DirEntry, valid_count);
        var current_idx: usize = 0;
        for (entries) |entry| {
            if (entry.name_len > 0) {
                results[current_idx] = entry;
                current_idx += 1;
            }
        }

        return results;
    }

};

fn initEmptyRootDir(device: *BlockDevice, extent: Extent) !void {
    // Allocate a buffer the size of the whole extent
    const total_size = extent.block_count * device.block_size;

    // In a kernel, you might use a smaller buffer and loop,
    // but for 4 blocks (2KB), this is fine:
    var buf: [2048]u8 = undefined;
    @memset(buf[0..], 0);

    try device.writeBlocks(device.ctx, extent.start_block, buf[0..total_size]);
}

pub fn breakpoint(msg: []const u8) void {
    vga.writeString(msg, 0, 0);
    while (true) asm volatile ("hlt");
}

pub fn addBlockToFile(fs: *CodaFs, allocator: std.mem.Allocator, meta: *FileMeta) !void {
    _ = allocator; // Explicitly discard the unused parameter

    if (meta.extent_count >= 8) return error.FileAtMaximumSize;

    // 1. Ask SpaceManager for a new block
    // (Note: If your allocate function DOES need an allocator,
    // you would pass it here instead of discarding it above)
    const new_extent = try fs.space_manager.allocate(1);

    // 2. Add it to the metadata's extent array
    meta.extents[meta.extent_count] = new_extent;
    meta.extent_count += 1;
}
