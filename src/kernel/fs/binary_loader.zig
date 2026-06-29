//src/kernel/fs/binary_loader.zig

const std = @import("std");
const ata = @import("../drivers/ata.zig");
const conf = @import("../config.zig");
const CodaFs = @import("coda_fs.zig").CodaFs;
const FileMeta = @import("coda_file.zig").FileMeta;
const Extent = @import("coda_sm.zig").Extent;
const DirEntry = @import("coda_file.zig").DirEntry;

pub const APP_LBA_START: u64 = 2000;
pub const APP_SECTORS: u32 = 9; // 4236 bytes rounded up to 512-byte boundaries

pub fn installEmbeddedApps(allocator: std.mem.Allocator, fs: *CodaFs) !void {
    // 1. Check if the application entry already exists to avoid duplication
    if (fs.findFile(allocator, fs.superblock.root_dir_extent_start, "prog1")) |_| {
        return; // Already staged, preserve state
    } else |err| {
        if (err != error.FileNotFound) return err;
    }

    // 2. Allocate an aligned in-memory staging buffer for the absolute ATA sector read
    const total_bytes = APP_SECTORS * conf.BLOCK_SIZE;
    const staging_buf = try allocator.alloc(u8, total_bytes);
    defer allocator.free(staging_buf);

    // 3. Read directly from physical hardware LBA 1024
    try ata.AtaDevice.readBlocks(null, APP_LBA_START, staging_buf);

    // 4. Allocate space inside the active file system manager
    const meta_extent = try fs.space_manager.allocate(1);
    const data_extent = try fs.space_manager.allocate(APP_SECTORS);

    // 5. Build on-disk FileMeta struct
    var meta = FileMeta{
        .file_type = .File,
        .size_bytes = 4236, // Exact physical byte size from stat
        .extent_count = 1,
        .extents = [_]Extent{.{ .start_block = 0, .block_count = 0 }} ** 8,
    };
    meta.extents[0] = data_extent;

    // 6. Write binary payloads directly to the underlying filesystem storage device
    const block_size = fs.device.block_size;
    const meta_buf = try allocator.alloc(u8, block_size);
    defer allocator.free(meta_buf);
    @memset(meta_buf, 0);
    @memcpy(meta_buf[0..@sizeOf(FileMeta)], std.mem.asBytes(&meta));

    try fs.device.writeBlocks(fs.device.ctx, meta_extent.start_block, meta_buf);
    try fs.device.writeBlocks(fs.device.ctx, data_extent.start_block, staging_buf);

    // 7. Inject name record into the Root Directory
    var entry = DirEntry{
        .name = [_]u8{0} ** 64,
        .name_len = 5,
        .meta_extent = meta_extent,
    };
    @memcpy(entry.name[0..5], "prog1");

    try fs.insertEntry(allocator, fs.superblock.root_dir_extent_start, entry);
    try fs.space_manager.flushToDisk(allocator, fs.superblock.sm_start_block, fs.superblock.sm_block_count);
}
