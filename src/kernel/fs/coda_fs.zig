// src/kernel/fs/coda_fs.zig
//
// CODA Filesystem — Core
// ----------------------
// Implements the core filesystem logic for CODA:
//   • Superblock layout and validation
//   • SpaceManager integration
//   • Directory and file metadata handling
//   • Path resolution
//   • Telemetry-aware block I/O
//
// This file contains NO caching, NO VFS layer, and NO buffering.
// All operations are direct, synchronous, and block-aligned.

const std        = @import("std");
const conf       = @import("../config.zig");
const memory     = @import("../memory.zig");
const vga        = @import("../vga.zig");
const vitals     = @import("../vitals.zig");
const BlockDevice = @import("block_device.zig").BlockDevice;
const Extent      = @import("coda_sm.zig").Extent;
const SpaceManager = @import("coda_sm.zig").SpaceManager;
const Directory  = @import("coda_file.zig").Directory;
const DirEntry   = @import("coda_file.zig").DirEntry;
const FileMeta   = @import("coda_file.zig").FileMeta;
const FileType   = @import("coda_file.zig").FileType;
const MAX_NAME   = @import("coda_file.zig").MAX_NAME;
const conv = @import("../convert.zig");

// --------------------------------
// Filesystem constants
// --------------------------------

pub const CODA_MAGIC:   u64 = 0x434F44415F465331;
pub const CODA_VERSION: u32 = 1;
pub const FLAG_DIRTY:   u64 = 1 << 0;  // 0x0000000000000001

// --------------------------------
// Public types
// --------------------------------

/// Telemetry record captured per block I/O operation.
pub const IoEvent = struct {
    lba:      u64,
    is_write: bool,
    cycles:   u64,
};

/// Operating policy embedded in the superblock.
/// Controls telemetry thresholds and future AI-guided behaviour.
pub const SystemPolicy = conf.SystemPolicy;

/// On-disk superblock describing the entire filesystem layout.
/// Read at mount time; written only by mkfs.
///
/// Invariants:
///   magic                  — must equal CODA_MAGIC
///   block_size             — must match the underlying device
///   sm_start_block / sm_block_count
///                          — define the SpaceManager region
///   root_dir_extent_start / root_dir_extent_blocks
///                          — define the root directory's physical extent
///   reserved[]             — must remain zeroed for forward compatibility
///
/// NOTE: This struct is written to disk verbatim via writeBlockStruct().
///       Any layout change is a breaking on-disk format change.
pub const Superblock = struct {
    magic:        u64,  // 8 bytes
    flags:        u64,  // 8 bytes
    version:      u32,  // 4 bytes
    block_size:   u32,  // 4 bytes (Total 24 - Good)
    total_blocks: u64,  // 8 bytes (Total 32 - Good)

    // Build policy awareness into the superblock
    policy: conf.SystemPolicy,          // 1 byte (from config.zig)
    _pad: [7]u8 = [_]u8{0} ** 7,        // 7 bytes (Total 8 - Perfect alignment!)

    latency_threshold_ns: u64,          // Now starts on a clean 8-byte boundary
    sm_start_block:       u64,
    sm_block_count:       u64,

    root_dir_extent_start:  u64,
    root_dir_extent_blocks: u64,

    reserved: [128]u8,
};

/// Result returned by resolvePath().
pub const PathResult = struct {
    lba:          u64,
    blocks:       u64,
    is_directory: bool,
};

// --------------------------------
// CodaFs — in-memory mount state
// --------------------------------

/// In-memory representation of a mounted CODA filesystem.
///
/// Holds:
///   device         — underlying block device
///   superblock     — validated copy of the on-disk superblock
///   space_manager  — extent allocator
///   root_dir       — lightweight handle (entries not preloaded)
///   brain_ptr      — optional opaque context for the Markov Brain
///   on_telemetry   — optional callback invoked after every I/O
///
/// NOT reference-counted. NOT thread-safe.
pub const CodaFs = struct {
    device:        *BlockDevice,
    superblock:    Superblock,
    space_manager: SpaceManager,
    root_dir:      Directory,
    brain_ptr:     ?*anyopaque = null,
    on_telemetry:  ?*const fn (ctx: ?*anyopaque, policy: SystemPolicy, cycles: u64) void = null,

    // ----------------------------------------------------------------
    // Mount / format
    // ----------------------------------------------------------------

    /// Mount an existing CODA filesystem.
    ///   1. Reads and validates the superblock
    ///   2. Loads the SpaceManager from disk
    ///   3. Prepares a lightweight root directory handle
    ///
    /// Does NOT preload directory contents.
    /// Does NOT verify directory integrity.
    /// Returns a fully initialised CodaFs instance.
    pub fn mount(allocator: std.mem.Allocator, device: *BlockDevice) !CodaFs {
        // 1. Read superblock from LBA SB_LBA set in config.zig
        var sb: Superblock = undefined;
        try readSuperblock(device, conf.SB_LBA, &sb);

        if (sb.magic != CODA_MAGIC) return error.InvalidMagic;

        // 2. Initialise SpaceManager from disk
        const sm = try SpaceManager.initFromDisk(
            allocator,
            device,
            sb.sm_start_block,
        );

        // 3. Prepare root directory handle (entries loaded on demand)
        const root_dir = Directory{
            .entries = &[_]DirEntry{},
        };

        return CodaFs{
            .device        = device,
            .superblock    = sb,
            .space_manager = sm,
            .root_dir      = root_dir,
        };
    }

    /// Allocates a 4-block root directory extent.
    /// Initialises SpaceManager and writes an empty root directory.
    /// Overwrites existing data without warning.
    pub fn mkfs(allocator: std.mem.Allocator, device: *BlockDevice) !void {
        if (device.block_size < conf.BASE_IO_BUF_SIZE) return error.InvalidBlockSize;

        const total_blocks: u64 = device.total_blocks;

        const sb_block:      u64 = conf.SB_LBA;
        const sm_start_block: u64 = conf.SB_LBA + 1;
        const sm_block_count: u64 = 16;

        const data_start_block = sm_start_block + sm_block_count;
        if (data_start_block >= total_blocks) return error.TooSmall;

        // SpaceManager tracks blocks from data_start_block (2065) onwards
        var sm = try SpaceManager.initFresh(
            allocator,
            device,
            data_start_block,
            total_blocks - data_start_block,
        );

        const root_extent = try sm.allocate(4);

        var sb = Superblock{
            .magic       = CODA_MAGIC,
            .version     = CODA_VERSION,
            .block_size  = @as(u32, @intCast(device.block_size)),
            .total_blocks = total_blocks,
            .policy               = conf.current_policy,    // Default operating policy
            .latency_threshold_ns = 28480,   // Placeholder baseline
            .sm_start_block  = sm_start_block,
            .sm_block_count  = sm_block_count,
            .root_dir_extent_start  = root_extent.start_block,
            .root_dir_extent_blocks = root_extent.block_count,
            .flags   = 0,
            .reserved = [_]u8{0} ** 128,
        };


        try sm.flushToDisk(allocator, sm_start_block, sm_block_count);
        try initEmptyRootDir(device, root_extent);
        try writeSuperblock(device, sb_block, &sb);
    }

    // ----------------------------------------------------------------
    // File / directory lookup and creation
    // ----------------------------------------------------------------

    /// Search a single directory for an entry by name.
    /// Loads all directory blocks, scans entries, and returns the matching DirEntry.
    ///
    /// Does NOT follow paths — single-directory lookup only.
    /// Returns error.FileNotFound if no match exists.
    pub fn findFile(fs: *CodaFs, allocator: std.mem.Allocator, dir_lba: u64, name: []const u8) !DirEntry {
        // 1. Determine how many blocks to search
        var blocks_to_search: u64 = 1;
        if (dir_lba == fs.superblock.root_dir_extent_start) {
            blocks_to_search = fs.superblock.root_dir_extent_blocks;
        } else {
            const meta = try fs.readFileMeta(allocator, dir_lba);
            blocks_to_search = meta.extent_count;
        }

        // 2. Load all entries for those blocks
        const entries = try fs.listDir(allocator, dir_lba, blocks_to_search);
        defer allocator.free(entries);

        for (entries) |entry| {
            if (entry.name_len == 0) continue;
            if (std.mem.eql(u8, entry.name[0..entry.name_len], name)) {
                return entry;
            }
        }

        return error.FileNotFound;
    }

    /// Create a new file or directory inside a parent directory.
    ///
    /// Steps:
    ///   1. Verify the name does not already exist
    ///   2. Allocate a metadata block and a first data block
    ///   3. Initialise FileMeta
    ///   4. Zero-fill data blocks for directories
    ///   5. Insert a DirEntry into the parent (auto-growing subdirectories)
    ///
    /// `dir_blocks` is retained for signature compatibility but unused here.
    pub fn createEntry(
        fs:        *CodaFs,
        allocator: std.mem.Allocator,
        dir_lba:   u64,
        dir_blocks: u64,
        name:      []const u8,
        file_type: FileType,
    ) !void {
        _ = dir_blocks;

        if (name.len > MAX_NAME) return error.NameTooLong;

        // 1. Reject duplicates
        if (fs.findFile(allocator, dir_lba, name)) |_| {
            return error.AlreadyExists;
        } else |err| {
            if (err != error.FileNotFound) return err;
        }

        // 2. Allocate metadata block and first data block
        const meta_extent = try fs.space_manager.allocate(1);
        const data_extent = try fs.space_manager.allocate(1);

        // 3. Initialise FileMeta
        var meta = FileMeta{
            .file_type    = file_type,
            .size_bytes   = 0,
            .extent_count = 1,
            .extents      = [_]Extent{.{ .start_block = 0, .block_count = 0 }} ** 8,
        };
        meta.extents[0] = data_extent;

        // 4. Zero-fill the data block for directories (no junk entries)
        if (file_type == .Directory) {
            const dir_init_buf = try allocator.alloc(u8, fs.device.block_size);
            defer allocator.free(dir_init_buf);
            @memset(dir_init_buf, 0);
            try fs.device.writeBlocks(fs.device.ctx, data_extent.start_block, dir_init_buf);
            meta.size_bytes = fs.device.block_size;
        }

        // 5. Write FileMeta to disk (ensure the ENTIRE block is clean)
        const meta_buf = try allocator.alloc(u8, fs.device.block_size);
        defer allocator.free(meta_buf);
        @memset(meta_buf, 0); // Wipe out any previous disk garbage

        // Copy your clean struct into the start of the clean buffer
        const meta_bytes = std.mem.asBytes(&meta);
        @memcpy(meta_buf[0..meta_bytes.len], meta_bytes);

        // Write the full, clean block to disk
        try fs.device.writeBlocks(fs.device.ctx, meta_extent.start_block, meta_buf);

        // 6. Build and insert the DirEntry into the parent
        var new_entry = DirEntry{
            .name       = [_]u8{0} ** MAX_NAME,
            .name_len   = @as(u8, @intCast(name.len)),
            .meta_extent = meta_extent,
        };
        @memcpy(new_entry.name[0..name.len], name);

        // insertEntry auto-grows subdirectories when full
        try fs.insertEntry(allocator, dir_lba, new_entry);
        try fs.space_manager.flushToDisk(allocator, fs.superblock.sm_start_block, fs.superblock.sm_block_count);
    }

    /// Compatibility wrapper: create a regular file.
    pub fn createFile(fs: *CodaFs, allocator: std.mem.Allocator, dir_lba: u64, dir_blocks: u64, name: []const u8) !void {
        return fs.createEntry(allocator, dir_lba, dir_blocks, name, .File);
    }

    /// Delete a file or directory entry from a parent directory.
    ///
    /// Frees all data extents and the metadata block.
    /// Removes the DirEntry from the parent directory block.
    /// Does NOT recursively delete children — caller must enforce safety.
    pub fn deleteFile(fs: *CodaFs, allocator: std.mem.Allocator, dir_lba: u64, name: []const u8) !void {
        // 1. Locate the entry to obtain its metadata address
        const entry = try fs.findFile(allocator, dir_lba, name);

        // 2. Read metadata
        var meta = try fs.readFileMeta(allocator, entry.meta_extent.start_block);

        // 3. Free all data extents
        for (meta.extents[0..meta.extent_count]) |extent| {
            try fs.space_manager.free(allocator, extent);
        }

        // 4. Free the metadata block itself
        try fs.space_manager.free(allocator, Extent{
            .start_block = entry.meta_extent.start_block,
            .block_count = 1,
        });

        // 5. Remove entry from the directory block
        const dir_buf = try allocator.alloc(u8, fs.device.block_size);
        defer allocator.free(dir_buf);

        try fs.device.readBlocks(fs.device.ctx, dir_lba, dir_buf);

        const entries = @as([*]DirEntry, @ptrCast(@alignCast(dir_buf.ptr)))[0 .. fs.device.block_size / @sizeOf(DirEntry)];

        var found = false;
        for (entries) |*e| {
            if (e.name_len == name.len and std.mem.eql(u8, e.name[0..name.len], name)) {
                @memset(std.mem.asBytes(e), 0);
                found = true;
                break;
            }
        }

        if (!found) return error.FileNotFound;

        // 6. Persist directory changes and SpaceManager state
        try fs.device.writeBlocks(fs.device.ctx, dir_lba, dir_buf);
        try fs.space_manager.flushToDisk(allocator, fs.superblock.sm_start_block, fs.superblock.sm_block_count);
    }

    /// Stub — not yet implemented.
    pub fn readFile(fs: *CodaFs, path: []const u8, out: []u8) !usize {
        _ = fs;
        _ = path;
        _ = out;
        return error.NotImplemented;
    }

    /// Stub — not yet implemented.
    pub fn writeFile(fs: *CodaFs, path: []const u8, data: []const u8) !void {
        _ = fs;
        _ = path;
        _ = data;
        return error.NotImplemented;
    }

    // ----------------------------------------------------------------
    // Directory I/O
    // ----------------------------------------------------------------

    /// Load all valid DirEntry records from a directory.
    ///
    /// Supports both root (contiguous blocks) and subdirectories (extent-based).
    /// Returns a freshly allocated slice containing only non-empty entries.
    /// Caller must free the returned slice.
    pub fn listDir(fs: *CodaFs, allocator: std.mem.Allocator, dir_lba: u64, dir_blocks: u64) ![]DirEntry {
        _ = dir_blocks;

        const is_root = (dir_lba == fs.superblock.root_dir_extent_start);

        var meta: FileMeta = undefined;
        if (!is_root) {
            meta = try fs.readFileMeta(allocator, dir_lba);
            if (meta.file_type != .Directory) return error.NotADirectory;
        }

        const total_blocks = if (is_root) fs.superblock.root_dir_extent_blocks else meta.extent_count;
        const entries_per_block = fs.device.block_size / @sizeOf(DirEntry);
        const max_entries = total_blocks * entries_per_block;

        const workspace = try allocator.alloc(DirEntry, max_entries);
        defer allocator.free(workspace);

        var valid_count: usize = 0;

        var b: u32 = 0;
        while (b < total_blocks) : (b += 1) {
            const current_lba = if (is_root) dir_lba + b else meta.extents[b].start_block;
            if (current_lba == 0) continue;

            const buf = try allocator.alloc(u8, fs.device.block_size);
            defer allocator.free(buf);
            _ = try fs.device.readBlocks(fs.device.ctx, current_lba, buf);

            const raw_entries = @as([*]DirEntry, @ptrCast(@alignCast(buf.ptr)))[0..entries_per_block];
            for (raw_entries) |e| {
                if (e.name_len > 0) {
                    workspace[valid_count] = e;
                    valid_count += 1;
                }
            }
        }

        const result = try allocator.alloc(DirEntry, valid_count);
        @memcpy(result[0..valid_count], workspace[0..valid_count]);
        return result;
    }

    /// Insert a DirEntry into a directory.
    ///
    /// Root directory:
    ///   Fixed-size contiguous blocks; fails with error.DirectoryFull if no free slot.
    ///
    /// Subdirectories:
    ///   Extent-based; auto-grows by allocating new blocks when all slots are full.
    ///
    /// Updates FileMeta and writes all changes to disk.
    pub fn insertEntry(fs: *CodaFs, allocator: std.mem.Allocator, dest_meta_lba: u64, entry: DirEntry) !void {
        const is_root = (dest_meta_lba == fs.superblock.root_dir_extent_start);

        if (is_root) {
            // Root is a fixed contiguous extent
            var b: u64 = 0;
            while (b < fs.superblock.root_dir_extent_blocks) : (b += 1) {
                const current_lba = dest_meta_lba + b;
                const buf = try allocator.alloc(u8, fs.device.block_size);
                defer allocator.free(buf);

                try fs.device.readBlocks(fs.device.ctx, current_lba, buf);
                const entries = @as([*]DirEntry, @ptrCast(@alignCast(buf.ptr)))[0 .. fs.device.block_size / @sizeOf(DirEntry)];

                for (entries) |*e| {
                    if (e.name_len == 0) {
                        e.* = entry;
                        try fs.device.writeBlocks(fs.device.ctx, current_lba, buf);
                        return;
                    }
                }
            }
            return error.DirectoryFull;  // Root is fixed-size; cannot grow
        } else {
            // Subdirectory: scan existing extents for a free slot
            var meta = try fs.readFileMeta(allocator, dest_meta_lba);

            var i: u32 = 0;
            while (i < meta.extent_count) : (i += 1) {
                const extent = meta.extents[i];
                const buf = try allocator.alloc(u8, fs.device.block_size);
                defer allocator.free(buf);

                try fs.device.readBlocks(fs.device.ctx, extent.start_block, buf);
                const entries = @as([*]DirEntry, @ptrCast(@alignCast(buf.ptr)))[0 .. fs.device.block_size / @sizeOf(DirEntry)];

                for (entries) |*e| {
                    if (e.name_len == 0) {
                        e.* = entry;
                        try fs.device.writeBlocks(fs.device.ctx, extent.start_block, buf);
                        return;
                    }
                }
            }

            // No free slot found — grow the directory by one block
            if (meta.extent_count >= 8) return error.DirectoryPhysicallyFull;

            const new_block_extent = try fs.space_manager.allocate(1);

            const zero_buf = try allocator.alloc(u8, fs.device.block_size);
            defer allocator.free(zero_buf);
            @memset(zero_buf, 0);

            const new_entries = @as([*]DirEntry, @ptrCast(@alignCast(zero_buf.ptr)))[0 .. fs.device.block_size / @sizeOf(DirEntry)];
            new_entries[0] = entry;
            try fs.device.writeBlocks(fs.device.ctx, new_block_extent.start_block, zero_buf);

            meta.extents[meta.extent_count] = new_block_extent;
            meta.extent_count += 1;
            meta.size_bytes += fs.device.block_size;
            try fs.writeBlockStruct(dest_meta_lba, &meta, @sizeOf(FileMeta));
        }
    }

    /// Locate and remove a DirEntry from a directory.
    /// Zeroes the entry in-place and returns a copy of the removed DirEntry.
    /// Used internally by deleteFile and rename operations.
    /// Works for both root and subdirectories.
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
                const copy = entry.*;
                entry.name_len = 0;
                try fs.device.writeBlocks(fs.device.ctx, data_lba, buf);
                return copy;
            }
        }

        return error.FileNotFound;
    }

    /// Rewrite all directory entries back to disk, packing them sequentially.
    /// Supports both root (contiguous) and subdirectories (extent-based).
    /// Caller must ensure `entries` is already filtered and ordered correctly.
    pub fn saveDirectoryEntries(fs: *CodaFs, allocator: std.mem.Allocator, dir_lba: u64, entries: []DirEntry) !void {
        const is_root = (dir_lba == fs.superblock.root_dir_extent_start);

        var total_blocks: u64 = 0;
        var meta: FileMeta = undefined;

        if (is_root) {
            total_blocks = fs.superblock.root_dir_extent_blocks;
        } else {
            meta = try fs.readFileMeta(allocator, dir_lba);
            total_blocks = meta.extent_count;
        }

        const entries_per_block = fs.device.block_size / @sizeOf(DirEntry);
        var entry_index: usize = 0;

        var b: u32 = 0;
        while (b < total_blocks) : (b += 1) {
            const current_lba = if (is_root) dir_lba + b else meta.extents[b].start_block;
            if (current_lba == 0) continue;

            const buf = try allocator.alloc(u8, fs.device.block_size);
            defer allocator.free(buf);
            @memset(buf, 0);

            const block_entries = @as([*]DirEntry, @ptrCast(@alignCast(buf.ptr)))[0..entries_per_block];

            var i: usize = 0;
            while (i < entries_per_block and entry_index < entries.len) : (i += 1) {
                block_entries[i] = entries[entry_index];
                entry_index += 1;
            }

            _ = try fs.device.writeBlocks(fs.device.ctx, current_lba, buf);
        }
    }

    /// Write an in-memory Directory struct back to disk.
    /// Used for the root directory only (stored as a contiguous extent).
    /// Also flushes SpaceManager state.
    /// Caller must ensure `dir.entries` matches the on-disk layout exactly.
    pub fn flushDirectory(self: *CodaFs, allocator: std.mem.Allocator, dir: Directory) !void {
        const dir_size = self.superblock.root_dir_extent_blocks * self.device.block_size;
        const root_lba = self.superblock.root_dir_extent_start;

        const ptr: [*]const u8 = @ptrCast(dir.entries.ptr);
        const raw_bytes = ptr[0..dir_size];

        try self.device.writeBlocks(self.device.ctx, root_lba, raw_bytes);
        try self.space_manager.flushToDisk(allocator, self.superblock.sm_start_block, self.superblock.sm_block_count);
    }

    // ----------------------------------------------------------------
    // Metadata I/O
    // ----------------------------------------------------------------

    /// Load a FileMeta struct from disk.
    /// Reads exactly one block at `meta_lba` and interprets it as FileMeta.
    /// Returns a copy; caller owns the struct.
    /// No caching or validation beyond trusting the on-disk layout.
    pub fn readFileMeta(fs: *CodaFs, allocator: std.mem.Allocator, meta_lba: u64) !FileMeta {
        const buf = try allocator.alloc(u8, fs.device.block_size);
        defer allocator.free(buf);

        _ = try fs.readBlocksWithTelemetry(meta_lba, buf);

        const meta_ptr = @as(*FileMeta, @ptrCast(@alignCast(buf.ptr)));
        return meta_ptr.*;
    }

    /// Write an arbitrary struct to a single disk block.
    /// Zero-fills the block, copies `size` bytes from `ptr`, then writes it.
    /// Used for FileMeta and other fixed-size on-disk structures.
    /// Caller must ensure `size <= block_size`.
    pub fn writeBlockStruct(self: *CodaFs, lba: u64, ptr: *const anyopaque, size: usize) !void {
        var buf: [conf.BASE_IO_BUF_SIZE]u8 = undefined;
        @memset(buf[0..], 0);

        const src = @as([*]const u8, @ptrCast(ptr))[0..size];
        _ = memory.memcpy(buf[0..size].ptr, src.ptr, size);

        _ = try self.writeBlocksWithTelemetry(lba, buf[0..self.device.block_size]);

    }

    /// Append a new data block to a file's extent list.
    /// Allocates one new extent of 1 block and updates FileMeta on disk.
    /// Returns the LBA of the newly allocated block.
    /// Fails with error.FileTooManyExtents if the file already has 8 extents.
    pub fn appendBlockToFile(self: *CodaFs, allocator: std.mem.Allocator, meta_lba: u64, meta: *FileMeta) !u64 {
        _ = allocator;

        const new_extent = try self.space_manager.allocate(1);

        if (meta.extent_count >= 8) return error.FileTooManyExtents;

        meta.extents[meta.extent_count] = new_extent;
        meta.extent_count += 1;

        try self.writeBlockStruct(meta_lba, meta, @sizeOf(FileMeta));
        return new_extent.start_block;
    }

    /// Append a new data block to a file via its FileMeta pointer.
    /// Updates the in-memory FileMeta and flushes SpaceManager to disk.
    /// Fails with error.FileAtMaximumSize if the file already has 8 extents.
    pub fn addBlockToFile(fs: *CodaFs, allocator: std.mem.Allocator, meta: *FileMeta) !void {
        if (meta.extent_count >= 8) return error.FileAtMaximumSize;

        const new_extent = try fs.space_manager.allocate(1);
        meta.extents[meta.extent_count] = new_extent;
        meta.extent_count += 1;

        try fs.space_manager.flushToDisk(allocator, fs.superblock.sm_start_block, fs.superblock.sm_block_count);
    }

    // ----------------------------------------------------------------
    // Path resolution
    // ----------------------------------------------------------------

    /// Resolve a filesystem path into a PathResult.
    ///
    /// Supports:
    ///   • Absolute paths  (/foo/bar)
    ///   • Relative paths  (foo/bar)
    ///   • "." and ".."   (non-recursive; ".." is a no-op for now)
    ///
    /// Walks directories one segment at a time using findFile.
    /// Returns metadata LBA + block count + directory flag.
    /// Does NOT follow symlinks (not implemented).
    pub fn resolvePath(fs: *CodaFs, allocator: std.mem.Allocator, start_dir_lba: u64, path: []const u8) !PathResult {
        if (path.len == 0) return error.EmptyPath;

        var current_lba:    u64 = 0;
        var current_blocks: u64 = 1;
        var remaining_path: []const u8 = "";

        // 1. Determine start: absolute ("/...") or relative
        if (path[0] == '/') {
            current_lba    = fs.superblock.root_dir_extent_start;
            current_blocks = fs.superblock.root_dir_extent_blocks;
            remaining_path = path[1..];
        } else {
            current_lba    = start_dir_lba;
            current_blocks = 1;
            remaining_path = path;
        }

        // 2. Short-circuit for root, ".", or ".."
        if (remaining_path.len == 0 or
            std.mem.eql(u8, remaining_path, ".") or
            std.mem.eql(u8, remaining_path, ".."))
        {
            return PathResult{
                .lba          = current_lba,
                .blocks       = current_blocks,
                .is_directory = true,
            };
        }

        // 3. Walk the tree segment by segment
        var it = std.mem.tokenizeScalar(u8, remaining_path, '/');
        while (it.next()) |segment| {
            if (std.mem.eql(u8, segment, "."))  continue;
            if (std.mem.eql(u8, segment, "..")) continue;  // Parent traversal not yet implemented

            const entry = fs.findFile(allocator, current_lba, segment) catch |err| {
                if (err == error.FileNotFound) return error.PathNotFound;
                return err;
            };

            const meta = try fs.readFileMeta(allocator, entry.meta_extent.start_block);

            if (it.peek() != null) {
                // Intermediate segment — must be a directory
                if (meta.file_type != .Directory) return error.NotADirectory;
                current_lba    = entry.meta_extent.start_block;
                current_blocks = meta.extent_count;
            } else {
                // Final segment
                return PathResult{
                    .lba          = entry.meta_extent.start_block,
                    .blocks       = meta.extent_count,
                    .is_directory = (meta.file_type == .Directory),
                };
            }
        }

        return error.PathNotFound;
    }

    // ----------------------------------------------------------------
    // Telemetry-instrumented block I/O
    // ----------------------------------------------------------------

    /// Read a block, measuring cycle latency for telemetry.
    /// Updates vitals and invokes the policy callback if registered.
    /// Switches policy to Admin if latency exceeds the superblock threshold.
    /// Returns the measured duration in CPU cycles.
    pub fn readBlocksWithTelemetry(self: *CodaFs, lba: u64, buf: []u8) !u64 {
        const start = getCycles();
        try self.device.readBlocks(self.device.ctx, lba, buf);
        const end = getCycles();
        const duration = end - start;

        vitals.current_vitals.disk_cycles += duration;
        vitals.current_vitals.last_read_latency = duration;

        if (self.on_telemetry) |callback| {
            callback(self.brain_ptr, self.superblock.policy, duration);
        }

        // Sentinel: escalate to Admin if latency is anomalously high
        // NOTE: latency_threshold_ns is compared against raw cycle counts here;
        //       calibrate the multiplier (×10) to your CPU frequency.
        if (duration > self.superblock.latency_threshold_ns * 10) {
            self.superblock.policy = .ADMIN;
        }

        return duration;
    }

    /// Write a block, measuring cycle latency for telemetry.
    /// Returns the measured duration in CPU cycles.
    /// Hook for future Markov Brain integration.
    pub fn writeBlocksWithTelemetry(self: *CodaFs, lba: u64, buf: []const u8) !u64 {
        const start = getCycles();
        try self.device.writeBlocks(self.device.ctx, lba, buf);
        const end = getCycles();
        const duration = end - start;

        // TODO: Feed duration to Markov Brain when ready.
        // e.g., g_brain.addObservation(self.superblock.policy, duration);

        return duration;
    }

    // ----------------------------------------------------------------
    // CPU cycle counter
    // ----------------------------------------------------------------

    /// Read the CPU timestamp counter (RDTSC).
    /// Returns a raw cycle count; no normalisation is applied.
    /// Used for telemetry and I/O latency measurement.
    pub fn getCycles() u64 {
        return asm volatile ("rdtsc" : [ret] "={ax}" (-> u64) : : .{ .edx = true });
    }

    // Sync the Superblock to the correct location
    pub fn syncSuperblock(self: *CodaFs) !void {
        const sb_block: u64 = conf.SB_LBA;
        // We call the existing writeSuperblock helper used by mkfs
        try writeSuperblock(self.device, sb_block, &self.superblock);
    }

};

// ----------------------------------------------------------------
// File-private helpers  (called only from within this file)
// ----------------------------------------------------------------

/// Zero-fill the entire root directory extent.
/// Called only during mkfs.
/// Writes a clean, empty directory block sequence.
fn initEmptyRootDir(device: *BlockDevice, extent: Extent) !void {
    const total_size = extent.block_count * device.block_size;
    var buf: [conf.SB_LBA]u8 = undefined;
    @memset(buf[0..], 0);
    try device.writeBlocks(device.ctx, extent.start_block, buf[0..total_size]);
}

/// Serialise a Superblock into a single disk block and write it.
fn writeSuperblock(device: *BlockDevice, lba: u64, sb: *const Superblock) !void {
    var buf: [conf.BASE_IO_BUF_SIZE]u8 = undefined;
    @memset(buf[0..], 0);

    const src = @as([*]const u8, @ptrCast(sb))[0..@sizeOf(Superblock)];
    _ = memory.memcpy(buf[0..src.len].ptr, src.ptr, src.len);

    try device.writeBlocks(device.ctx, lba, buf[0..device.block_size]);
}

/// Read a single disk block and deserialise it into a Superblock.
fn readSuperblock(device: *BlockDevice, lba: u64, sb: *Superblock) !void {
    var buf: [conf.BASE_IO_BUF_SIZE]u8 = undefined;
    try device.readBlocks(device.ctx, lba, buf[0..device.block_size]);

    const dst = @as([*]u8, @ptrCast(sb))[0..@sizeOf(Superblock)];
    _ = memory.memcpy(dst.ptr, buf[0..dst.len].ptr, dst.len);
}

/// Halt the CPU and display a debug message.
/// Intended as a kernel-level breakpoint for development only.
pub fn breakpoint(msg: []const u8) void {
    vga.writeString(msg, 0, 0);
    while (true) asm volatile ("hlt");
}
