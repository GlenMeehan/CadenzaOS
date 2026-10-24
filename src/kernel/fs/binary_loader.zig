// src/kernel/fs/binary_loader.zig

const std = @import("std");
const ata = @import("../drivers/ata.zig");
const conf = @import("../config.zig");
const CodaFs = @import("coda_fs.zig").CodaFs;
const FileMeta = @import("coda_file.zig").FileMeta;
const Extent = @import("coda_sm.zig").Extent;
const DirEntry = @import("coda_file.zig").DirEntry;
const binfmt = @import("../binfmt.zig");
const bundle = @import("../bundlefmt.zig");

/// Absolute disk LBA of the raw app staging area.
///
/// build.sh packs every program under userland/ into one bundle (see
/// bundlefmt.zig) and writes it here, outside the filesystem. At first boot
/// the programs are copied into the filesystem as ordinary files.
pub const APP_LBA_START: u64 = conf.APP_LBA_START;

/// Import the staged program bundle into the filesystem.
///
/// Every program in the bundle that does not already exist in the root
/// directory is installed under its bundle name. Existing files are left
/// alone, so a preserved filesystem keeps its current copies.
pub fn installEmbeddedApps(allocator: std.mem.Allocator, fs: *CodaFs) !void {
    const sector: usize = conf.BLOCK_SIZE;

    // 1. Read sector 0: the bundle header and the table of programs.
    const first = try allocator.alloc(u8, sector);
    defer allocator.free(first);
    try ata.AtaDevice.readBlocks(null, APP_LBA_START, first);

    const bh = bundle.parseHeader(first) catch return error.InvalidBundle;
    if (bh.total_sectors < 2 or bh.total_sectors > conf.APP_MAX_SECTORS)
        return error.InvalidBundle;

    // 2. Install each program in the table.
    var i: usize = 0;
    while (i < bh.count) : (i += 1) {
        const e = bundle.entryAt(first, i);
        const name = bundle.entryName(&e) orelse return error.InvalidBundle;

        // The program must lie inside the bundle, after the table sector.
        const size: usize = e.size_bytes;
        const nsec: u64 = (size + sector - 1) / sector;
        if (e.offset_sectors < 1 or @as(u64, e.offset_sectors) + nsec > bh.total_sectors)
            return error.InvalidBundle;

        try installOne(allocator, fs, name, e.offset_sectors, size);
    }
}

/// Install one program from the bundle as a root-directory file.
fn installOne(
    allocator: std.mem.Allocator,
    fs: *CodaFs,
    name: []const u8,
    offset_sectors: u32,
    size: usize,
) !void {
    const root = fs.superblock.root_dir_extent_start;

    // 1. Skip programs that are already installed.
    if (fs.findFile(allocator, root, name)) |_| {
        return;
    } else |err| {
        if (err != error.FileNotFound) return err;
    }

    // 2. Read the program's sectors from the raw staging area.
    const sector: usize = conf.BLOCK_SIZE;
    const sectors: u32 = @intCast((size + sector - 1) / sector);

    const staging_buf = try allocator.alloc(u8, @as(usize, sectors) * sector);
    defer allocator.free(staging_buf);
    try ata.AtaDevice.readBlocks(null, APP_LBA_START + offset_sectors, staging_buf);

    // 3. Check the program's own header before installing anything.
    const hdr = binfmt.parse(staging_buf[0..size]) catch return error.InvalidProgramImage;

    // 4. Allocate filesystem space: one metadata block and the payload.
    //    If anything fails before the directory entry exists, give both extents back.
    var linked = false;
    const meta_extent = try fs.space_manager.allocate(1);
    errdefer if (!linked) {
        fs.space_manager.free(allocator, meta_extent) catch {};
    };
    const data_extent = try fs.space_manager.allocate(sectors);
    errdefer if (!linked) {
        fs.space_manager.free(allocator, data_extent) catch {};
    };

    // 5. File metadata uses the true program size from the program header.
    var meta = FileMeta{
        .file_type = .File,
        .size_bytes = hdr.image_size,
        .extent_count = 1,
        .extents = [_]Extent{.{ .start_block = 0, .block_count = 0 }} ** 8,
    };
    meta.extents[0] = data_extent;

    // 6. Write the metadata block and the payload to the filesystem's device.
    const block_size = fs.device.block_size;

    const meta_buf = try allocator.alloc(u8, block_size);
    defer allocator.free(meta_buf);

    @memset(meta_buf, 0);
    @memcpy(meta_buf[0..@sizeOf(FileMeta)], std.mem.asBytes(&meta));

    try fs.device.writeBlocks(fs.device.ctx, meta_extent.start_block, meta_buf);
    try fs.device.writeBlocks(fs.device.ctx, data_extent.start_block, staging_buf);

    // 7. Add the directory entry and persist the space manager state.
    var entry = DirEntry{
        .name = [_]u8{0} ** 64,
        .name_len = @as(u8, @intCast(name.len)),
        .meta_extent = meta_extent,
    };
    @memcpy(entry.name[0..name.len], name);

    try fs.insertEntry(allocator, root, entry);
    linked = true;

    try fs.space_manager.flushToDisk(
        allocator,
        fs.superblock.sm_start_block,
        fs.superblock.sm_block_count,
    );
}
