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
const FileType = @import("coda_file.zig").FileType;

pub const CODA_MAGIC: u64 = 0x434F44415F465331;
pub const CODA_VERSION: u32 = 1;
pub const FLAG_DIRTY: u64 = 1 << 0; // Value: 0x0000000000000001

pub const IoEvent = struct {
    lba: u64,
    is_write: bool,
    cycles: u64,
};

pub const SystemPolicy = enum(u32) {
    Admin = 0,
    Dev = 1,
    Gaming = 2,
    AI_Guided = 3, // For Phase 4!
};


pub const Superblock = struct {
    magic: u64,
    flags: u64,
    version: u32,
    block_size: u32,
    total_blocks: u64,

    // Buidl policy awareness into superblock
    policy: SystemPolicy,
    latency_threshold_ns: u64, // Baseline for anomaly detection

    sm_start_block: u64,
    sm_block_count: u64,

    root_dir_extent_start: u64,
    root_dir_extent_blocks: u64,

    reserved: [128]u8,
};

pub const PathResult = struct {
    lba: u64,
    blocks: u64,
    is_directory: bool,
};

pub const CodaFs = struct {
    device: *BlockDevice,
    superblock: Superblock,
    space_manager: SpaceManager,
    root_dir: Directory,
    // Searches the root directory for a filename and returns its metadata LBA
    pub fn findFile(fs: *CodaFs, allocator: std.mem.Allocator, dir_lba: u64, name: []const u8) !u64 {
        // 1. Get the entries for this specific directory
        // We assume directories are 1 block for now; otherwise, pass dir_blocks too
        const entries = try fs.listDir(allocator, dir_lba, 1);
        defer allocator.free(entries);

        for (entries) |entry| {
            const entry_name = entry.name[0..entry.name_len];
            if (std.mem.eql(u8, entry_name, name)) {
                return entry.meta_extent.start_block;
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
        _ = try fs.readBlocksWithTelemetry(meta_lba, buf);

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
            // --- Policy awareness fields ---
            .policy = .Dev,                // Default to Dev mode
            .latency_threshold_ns = 1000,  // A placeholder baseline
            // ----------------------------
            .sm_start_block = sm_start_block,
            .sm_block_count = sm_block_count,
            .root_dir_extent_start = root_extent.start_block,
            .root_dir_extent_blocks = root_extent.block_count,
            .flags = 0,
            .reserved = [_]u8{0} ** 128,
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



    // 1. The new Generalized Function
    pub fn createEntry(
        fs: *CodaFs,
        allocator: std.mem.Allocator,
        dir_lba: u64,     // The LBA of the parent (Metadata LBA or Superblock)
    dir_blocks: u64,  // Size of the parent directory
    name: []const u8,
    file_type: FileType
    ) !void {
        if (name.len > MAX_NAME) return error.NameTooLong;

        // 1. Check if file already exists in this specific directory
        if (fs.findFile(allocator, dir_lba, name)) |_| {
            return error.AlreadyExists;
        } else |err| {
            if (err != error.FileNotFound) return err;
        }

        // 2. Allocate space for the new item's metadata and data
        const meta_extent = try fs.space_manager.allocate(1);
        const data_extent = try fs.space_manager.allocate(1);

        // 3. Initialize the new FileMeta
        var meta = FileMeta{
            .file_type = file_type,
            .size_bytes = 0,
            .extent_count = 1,
            .extents = [_]Extent{.{ .start_block = 0, .block_count = 0 }} ** 8,
        };
        meta.extents[0] = data_extent;

        // 4. If creating a directory, format its data block with zeros (no entries)
        if (file_type == .Directory) {
            const dir_init_buf = try allocator.alloc(u8, fs.device.block_size);
            defer allocator.free(dir_init_buf);
            @memset(dir_init_buf, 0);

            try fs.device.writeBlocks(fs.device.ctx, data_extent.start_block, dir_init_buf);
            meta.size_bytes = fs.device.block_size;
        }

        // 5. Write the new FileMeta to disk
        const meta_bytes = @as([*]const u8, @ptrCast(&meta))[0..@sizeOf(FileMeta)];
        // We need a full block buffer to ensure we don't write "short" to disk
        const block_buf = try allocator.alloc(u8, fs.device.block_size);
        defer allocator.free(block_buf);
        @memset(block_buf, 0);
        @memcpy(block_buf[0..@sizeOf(FileMeta)], meta_bytes);

        try fs.device.writeBlocks(fs.device.ctx, meta_extent.start_block, block_buf);

        // --- 6. Resolve the Parent's DATA LBA ---
        // If dir_lba is the root, its entries are at root_dir_extent_start.
        // Otherwise, it's a subfolder, so we find its data extent via its metadata.

        var parent_data_lba: u64 = 0;
        if (dir_lba == fs.superblock.root_dir_extent_start) {
            parent_data_lba = dir_lba;
        } else {
            const parent_meta = try fs.readFileMeta(allocator, dir_lba);
            parent_data_lba = parent_meta.extents[0].start_block;
        }

        // 7. Load the Parent Directory's Entries
        const dir_size = dir_blocks * fs.device.block_size;
        const dir_buf = try allocator.alloc(u8, dir_size);
        defer allocator.free(dir_buf);

        try fs.device.readBlocks(fs.device.ctx, parent_data_lba, dir_buf);

        const entry_count = dir_size / @sizeOf(DirEntry);
        const entries = @as([*]DirEntry, @ptrCast(@alignCast(dir_buf.ptr)))[0..entry_count];
        var dir = Directory{ .entries = entries };

        // 8. Add the new entry to the parent's list
        var new_entry = DirEntry{
            .name = [_]u8{0} ** MAX_NAME,
            .name_len = @as(u8, @intCast(name.len)),
            .meta_extent = meta_extent,
        };
        @memcpy(new_entry.name[0..name.len], name);

        try dir.addEntry(new_entry);

        // 9. Write the updated entry list back to the DATA LBA
        try fs.device.writeBlocks(fs.device.ctx, parent_data_lba, dir_buf);
    }

    // The Compatibility Wrapper
    pub fn createFile(fs: *CodaFs, allocator: std.mem.Allocator, dir_lba: u64, dir_blocks: u64, name: []const u8) !void {
        return fs.createEntry(allocator, dir_lba, dir_blocks, name, .File);
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

    pub fn deleteFile(fs: *CodaFs, allocator: std.mem.Allocator, dir_lba: u64, name: []const u8) !void {
        // 1. Use 'fs' instead of 'self' here:
        const meta_lba = try fs.findFile(allocator, dir_lba, name);

        // 2. And use 'fs' instead of 'self' here:
        var meta = try fs.readFileMeta(allocator, meta_lba);

        // 3. Free all data extents
        for (meta.extents[0..meta.extent_count]) |extent| {
            // Pass the allocator down to the space manager
            try fs.space_manager.free(allocator, extent);
        }

        // 4. Free the metadata block itself
        try fs.space_manager.free(allocator, Extent{ .start_block = meta_lba, .block_count = 1 });

        // 5. Remove the entry from the directory
        const dir_buf = try allocator.alloc(u8, fs.device.block_size);
        defer allocator.free(dir_buf);

        try fs.device.readBlocks(fs.device.ctx, dir_lba, dir_buf);

        const entries = @as([*]DirEntry, @ptrCast(@alignCast(dir_buf.ptr)))[0 .. fs.device.block_size / @sizeOf(DirEntry)];

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
        try fs.device.writeBlocks(fs.device.ctx, dir_lba, dir_buf);
        try fs.space_manager.flushToDisk(allocator, fs.superblock.sm_start_block, fs.superblock.sm_block_count);
    }

    pub fn listDir(fs: *CodaFs, allocator: std.mem.Allocator, dir_lba: u64, dir_blocks: u64) ![]DirEntry {
        // 1. RESOLVE DATA LBA
        // If we are at the root, the entries are at the root start.
        // Otherwise, dir_lba is a Metadata block, and we must find the Data block.
        var data_lba = dir_lba;
        if (dir_lba != fs.superblock.root_dir_extent_start) {
            const meta = try fs.readFileMeta(allocator, dir_lba);
            if (meta.file_type != .Directory) return error.NotADirectory;
            data_lba = meta.extents[0].start_block;
        }

        // 2. ALLOCATE AND READ
        const dir_size = dir_blocks * fs.device.block_size;
        const buf = try allocator.alloc(u8, dir_size);
        defer allocator.free(buf);

        // Read from the DATA block, not the Metadata block
        try fs.device.readBlocks(fs.device.ctx, data_lba, buf);

        // 3. PARSE ENTRIES
        const total_possible_entries = dir_size / @sizeOf(DirEntry);
        const raw_entries = @as([*]DirEntry, @ptrCast(@alignCast(buf.ptr)))[0..total_possible_entries];

        // Count valid entries (where name_len > 0)
        var count: usize = 0;
        for (raw_entries) |e| {
            if (e.name_len > 0) count += 1;
        }

        // Allocate the result slice for the shell
        const result = try allocator.alloc(DirEntry, count);
        var index: usize = 0;
        for (raw_entries) |e| {
            if (e.name_len > 0) {
                result[index] = e;
                index += 1;
            }
        }

        return result;
    }

    pub fn flushDirectory(self: *CodaFs, allocator: std.mem.Allocator, dir: Directory) !void {
        const dir_size = self.superblock.root_dir_extent_blocks * self.device.block_size;
        const root_lba = self.superblock.root_dir_extent_start;

        // Modern Zig @ptrCast: only 1 argument.
        // We cast the pointer to a many-item constant u8 pointer.
        const ptr: [*]const u8 = @ptrCast(dir.entries.ptr);
        const raw_bytes = ptr[0..dir_size];

        try self.device.writeBlocks(self.device.ctx, root_lba, raw_bytes);

        try self.space_manager.flushToDisk(allocator, self.superblock.sm_start_block, self.superblock.sm_block_count);
    }

    pub fn resolvePath(fs: *CodaFs, allocator: std.mem.Allocator, start_dir_lba: u64, path: []const u8) !PathResult {

        if (path.len == 0) return error.EmptyPath;

        var current_lba: u64 = 0;
        var current_blocks: u64 = 1;
        var remaining_path: []const u8 = "";

        // 1. Determine the starting point (Absolute vs Relative)
        if (path[0] == '/') {
            current_lba = fs.superblock.root_dir_extent_start;
            current_blocks = fs.superblock.root_dir_extent_blocks;
            remaining_path = path[1..];
        } else {
            current_lba = start_dir_lba;
            current_blocks = 1;
            remaining_path = path;
        }

        // 2. Immediate return for "/", ".", or ".." (if they are the only thing in the path)
        if (remaining_path.len == 0 or
            std.mem.eql(u8, remaining_path, ".") or
            std.mem.eql(u8, remaining_path, ".."))
        {
            return PathResult{
                .lba = current_lba,
                .blocks = current_blocks,
                .is_directory = true,
            };
        }

        // 3. Tokenize and Walk the tree
        var it = std.mem.tokenizeScalar(u8, remaining_path, '/');

        // --- THIS LINE WAS MISSING ---
        while (it.next()) |segment| {

            // Handle special segments in the loop
            if (std.mem.eql(u8, segment, ".")) continue;
            if (std.mem.eql(u8, segment, "..")) continue; // Add parent logic later

            // Search for the actual file/folder name
            const found_lba = fs.findFile(allocator, current_lba, segment) catch |err| {
                if (err == error.FileNotFound) return error.PathNotFound;
                return err;
            };

            const meta = try fs.readFileMeta(allocator, found_lba);

            if (it.peek() != null) {
                // Not at the end yet, so this MUST be a directory
                if (meta.file_type != .Directory) return error.NotADirectory;
                current_lba = meta.extents[0].start_block;
            } else {
                // We reached the final segment!
                return PathResult{
                    .lba = found_lba,
                    .blocks = meta.extent_count,
                    .is_directory = (meta.file_type == .Directory),
                };
            }
        }

        return error.PathNotFound;
    }
    pub fn findAndRemoveEntry(fs: *CodaFs, allocator: std.mem.Allocator, dir_lba: u64, dir_blocks: u64, name: []const u8) !DirEntry {
        var data_lba = dir_lba;
        if (dir_lba != fs.superblock.root_dir_extent_start) {
            const meta = try fs.readFileMeta(allocator, dir_lba);
            data_lba = meta.extents[0].start_block;
        }

        const dir_size = dir_blocks * fs.device.block_size;
        const buf = try allocator.alloc(u8, dir_size);
        defer allocator.free(buf);

        try fs.device.readBlocks(fs.device.ctx, data_lba, buf);

        const entry_count = dir_size / @sizeOf(DirEntry);
        const entries = @as([*]DirEntry, @ptrCast(@alignCast(buf.ptr)))[0..entry_count];

        for (entries) |*entry| {
            if (entry.name_len > 0 and std.mem.eql(u8, entry.name[0..entry.name_len], name)) {
                const copy = entry.*; // Save the entry to return it
                entry.name_len = 0;   // "Delete" it
                try fs.device.writeBlocks(fs.device.ctx, data_lba, buf);
                return copy;
            }
        }
        return error.FileNotFound;
    }

    pub fn insertEntry(
        fs: *CodaFs,
        allocator: std.mem.Allocator,
        dest_dir_lba: u64,
        dest_dir_blocks: u64,
        entry: DirEntry
    ) !void {
        // 1. Resolve Data LBA for destination
        var data_lba = dest_dir_lba;
        if (dest_dir_lba != fs.superblock.root_dir_extent_start) {
            const meta = try fs.readFileMeta(allocator, dest_dir_lba);
            data_lba = meta.extents[0].start_block;
        }

        // 2. Read the destination directory data
        const dir_size = dest_dir_blocks * fs.device.block_size;
        const buf = try allocator.alloc(u8, dir_size);
        defer allocator.free(buf);
        try fs.device.readBlocks(fs.device.ctx, data_lba, buf);

        const entry_count = dir_size / @sizeOf(DirEntry);
        const entries = @as([*]DirEntry, @ptrCast(@alignCast(buf.ptr)))[0..entry_count];

        // 3. Find an empty slot
        for (entries) |*e| {
            if (e.name_len == 0) {
                e.* = entry; // Paste the entire struct (name, meta_extent, etc.)
                try fs.device.writeBlocks(fs.device.ctx, data_lba, buf);
                return;
            }
        }

        return error.NoSpaceInDirectory;
    }

    pub fn readBlocksWithTelemetry(self: *CodaFs, lba: u64, buf: []u8) !u64 {
        const start = getCycles();

        // Call the actual hardware driver
        try self.device.readBlocks(self.device.ctx, lba, buf);

        const end = getCycles();
        const duration = end - start;

        // This is Phase 2 logic:
        // In a real OS, we might store this in a circular buffer
        // for the AI to analyze later.
        return duration;
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

pub fn getCycles() u64 {
    // This is a wrapper for the RDTSC instruction
    return asm volatile ("rdtsc" : [ret] "={ax}" (-> u64) : : "edx");
}


