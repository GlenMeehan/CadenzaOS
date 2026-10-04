// src/kernel/binfmt.zig
//
// Flat-binary program format (version 1)
// --------------------------------------
// Every program image starts with a 16-byte header, emitted by the program's
// linker script / prog1.zig. The kernel validates it before running anything.
//
// The program-side values (magic, version, flags) must stay in sync with the
// `.header` block in prog1.zig.

const std = @import("std");

pub const MAGIC: u32 = 0x50_5A_44_43; // bytes 'C','D','Z','P' on disk (little-endian)
pub const VERSION: u16 = 1;

/// Coarse sanity cap on a claimed image size. The real limit for installed
/// apps is the raw staging window, enforced in binary_loader.zig.
pub const MAX_IMAGE_SIZE: u32 = 1024 * 1024;

pub const BinHeader = extern struct {
    magic: u32,
    version: u16,
    flags: u16, // reserved, must be 0 for now
    entry_offset: u32, // from image base to the first instruction
    image_size: u32, // file-backed bytes the linker emitted
};

comptime {
    std.debug.assert(@sizeOf(BinHeader) == 16);
}

pub const Error = error{
    TooSmall,
    BadMagic,
    BadVersion,
    BadImageSize,
    BadEntry,
};

/// Validates the header fields only. Needs just the first 16 bytes, so the
/// installer can call it on a single sector before it knows the full size.
pub fn readHeader(bytes: []const u8) Error!BinHeader {
    if (bytes.len < @sizeOf(BinHeader)) return error.TooSmall;
    const h = std.mem.bytesToValue(BinHeader, bytes[0..@sizeOf(BinHeader)]);
    if (h.magic != MAGIC) return error.BadMagic;
    if (h.version != VERSION) return error.BadVersion;
    if (h.image_size < @sizeOf(BinHeader) or h.image_size > MAX_IMAGE_SIZE) return error.BadImageSize;
    return h;
}

/// Full validation against the image actually loaded into memory.
/// Used by cmd_spawn.
pub fn parse(image: []const u8) Error!BinHeader {
    const h = try readHeader(image);
    if (h.image_size > image.len) return error.BadImageSize; // claims more than was loaded
    if (h.entry_offset < @sizeOf(BinHeader) or h.entry_offset >= h.image_size) return error.BadEntry;
    return h;
}
