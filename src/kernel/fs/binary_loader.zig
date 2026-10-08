// src/kernel/fs/binary_loader.zig

const std = @import("std");
const ata = @import("../drivers/ata.zig");
const conf = @import("../config.zig");
const CodaFs = @import("coda_fs.zig").CodaFs;
const FileMeta = @import("coda_file.zig").FileMeta;
const Extent = @import("coda_sm.zig").Extent;
const DirEntry = @import("coda_file.zig").DirEntry;
const binfmt = @import("../binfmt.zig");

/// Absolute disk LBA at which embedded application images are staged.
///
/// The build process places application binaries in a raw disk region
/// outside the filesystem. During initialisation they are copied into
/// the filesystem as normal files.
pub const APP_LBA_START: u64 = 2000;

/// Largest application image accepted from the staging area.
///
/// 48 sectors assumes the filesystem begins at absolute sector 2048,
/// leaving sectors 2000-2047 available for raw application storage.
/// This assumption originates from the current build layout and should
/// be verified if the disk image structure changes.
const APP_MAX_SECTORS: u64 = 48;

/// Maximum permitted application image size in bytes.
const MAX_APP_BYTES: u64 = APP_MAX_SECTORS * conf.BLOCK_SIZE;

/// Import any staged application binaries into the filesystem.
///
/// Currently installs a single embedded application ("prog1") if it
/// does not already exist in the root directory.
pub fn installEmbeddedApps(allocator: std.mem.Allocator, fs: *CodaFs) !void {

    // 1. Skip installation if prog1 already exists.
    if (fs.findFile(allocator, fs.superblock.root_dir_extent_start, "prog1")) |_| {
        return;
    } else |err| {
        if (err != error.FileNotFound) return err;
    }

    // 2. Read the first sector and obtain the real image size
    //    from the binary header.
    const sector: usize = conf.BLOCK_SIZE;

    const probe = try allocator.alloc(u8, sector);
    defer allocator.free(probe);

    try ata.AtaDevice.readBlocks(null, APP_LBA_START, probe);

    const hdr = binfmt.readHeader(probe) catch return error.InvalidProgramImage;

    // Reject images that exceed the reserved staging region.
    if (hdr.image_size > MAX_APP_BYTES)
        return error.InvalidProgramImage;

    const sectors: u32 = @intCast((hdr.image_size + sector - 1) / sector);

    // 3. Allocate a staging buffer large enough for the entire image,
    //    then read it from the raw staging area.
    const staging_buf = try allocator.alloc(u8, sectors * sector);
    defer allocator.free(staging_buf);

    try ata.AtaDevice.readBlocks(null, APP_LBA_START, staging_buf);

    // 4. Allocate filesystem space for:
    //    - one metadata block
    //    - the application payload data
    const meta_extent = try fs.space_manager.allocate(1);
    const data_extent = try fs.space_manager.allocate(sectors);

    // 5. Build file metadata using the true program size read from
    //    the executable header rather than the padded sector count.
    var meta = FileMeta{
        .file_type = .File,
        .size_bytes = hdr.image_size,
        .extent_count = 1,
        .extents = [_]Extent{.{ .start_block = 0, .block_count = 0 }} ** 8,
    };

    meta.extents[0] = data_extent;

    // 6. Write the metadata block and file contents directly to the
    //    filesystem's underlying storage device.
    const block_size = fs.device.block_size;

    const meta_buf = try allocator.alloc(u8, block_size);
    defer allocator.free(meta_buf);

    @memset(meta_buf, 0);
    @memcpy(meta_buf[0..@sizeOf(FileMeta)], std.mem.asBytes(&meta));

    try fs.device.writeBlocks(fs.device.ctx, meta_extent.start_block, meta_buf);
    try fs.device.writeBlocks(fs.device.ctx, data_extent.start_block, staging_buf);

    // 7. Create a directory entry for the application in the root
    //    directory and persist the updated space manager state.
    var entry = DirEntry{
        .name = [_]u8{0} ** 64,
        .name_len = 5,
        .meta_extent = meta_extent,
    };

    @memcpy(entry.name[0..5], "prog1");

    try fs.insertEntry(
        allocator,
        fs.superblock.root_dir_extent_start,
        entry,
    );

    try fs.space_manager.flushToDisk(
        allocator,
        fs.superblock.sm_start_block,
        fs.superblock.sm_block_count,
    );
}
