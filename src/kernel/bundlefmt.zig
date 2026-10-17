// src/kernel/bundlefmt.zig
//
// Program bundle format (version 1)
// ---------------------------------
// build.sh packs every program under userland/ into one bundle, written to the
// raw app staging area at APP_LBA_START. At first boot installEmbeddedApps
// reads the bundle and creates one CodaFS file per program.
//
// All fields are little-endian. The bundle is made by tools/pack.sh, which must
// agree with this file.
//
//   sector 0   BundleHeader (16 bytes), then up to MAX_ENTRIES BundleEntry
//              records (40 bytes each)
//   sector 1+  the program images, each starting on a sector boundary

const std = @import("std");

pub const MAGIC: u32 = 0x425A4443; // bytes 'C','D','Z','B' on disk
pub const VERSION: u16 = 1;
pub const NAME_LEN: usize = 32; // includes the terminating NUL
pub const MAX_ENTRIES: usize = 12;
pub const SECTOR: usize = 512;

pub const BundleHeader = extern struct {
    magic: u32,
    version: u16,
    count: u16,
    total_sectors: u32, // whole bundle, including sector 0
    reserved: u32,
};

pub const BundleEntry = extern struct {
    name: [NAME_LEN]u8, // NUL padded
    offset_sectors: u32, // from the start of the bundle; at least 1
    size_bytes: u32, // true size of the program image
};

comptime {
    std.debug.assert(@sizeOf(BundleHeader) == 16);
    std.debug.assert(@sizeOf(BundleEntry) == 40);
    std.debug.assert(@sizeOf(BundleHeader) + MAX_ENTRIES * @sizeOf(BundleEntry) <= SECTOR);
}

pub const Error = error{ TooSmall, BadMagic, BadVersion, BadCount };

/// Validate the bundle header found at the start of sector 0.
pub fn parseHeader(sector0: []const u8) Error!BundleHeader {
    if (sector0.len < SECTOR) return error.TooSmall;
    const h = std.mem.bytesToValue(BundleHeader, sector0[0..@sizeOf(BundleHeader)]);
    if (h.magic != MAGIC) return error.BadMagic;
    if (h.version != VERSION) return error.BadVersion;
    if (h.count == 0 or h.count > MAX_ENTRIES) return error.BadCount;
    return h;
}

/// Copy entry `index` out of sector 0. The caller must have checked
/// `index < header.count`.
pub fn entryAt(sector0: []const u8, index: usize) BundleEntry {
    const off = @sizeOf(BundleHeader) + index * @sizeOf(BundleEntry);
    return std.mem.bytesToValue(BundleEntry, sector0[off..][0..@sizeOf(BundleEntry)]);
}

/// The entry's program name, or null if it is not a usable file name
/// (empty, not NUL terminated, or containing '/', spaces or control characters).
pub fn entryName(e: *const BundleEntry) ?[]const u8 {
    const len = std.mem.indexOfScalar(u8, &e.name, 0) orelse return null;
    if (len == 0) return null;
    for (e.name[0..len]) |c| {
        if (c <= 0x20 or c == '/' or c >= 0x7F) return null;
    }
    return e.name[0..len];
}
