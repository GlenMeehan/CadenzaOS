// src/kernel/binfmt.zig
//
// Flat-binary program format (version 1)
// --------------------------------------
//
// Every program image begins with a fixed 16-byte header emitted by the
// application's linker script. The kernel validates this header before
// allowing the image to be installed or executed.
//
// The program-side definitions (magic, version, flags, and layout)
// must remain synchronised with the `.header` block emitted by the
// corresponding application build.

const std = @import("std");

/// File format magic value.
///
/// Stored on disk as the byte sequence:
///     'C' 'D' 'Z' 'P'
///
/// The numeric value appears reversed due to little-endian encoding.
pub const MAGIC: u32 = 0x50_5A_44_43;

/// Current supported binary format version.
pub const VERSION: u16 = 1;

/// Coarse sanity limit used during header validation.
///
/// The true installation limit is determined by the available staging
/// region and is enforced separately by binary_loader.zig.
pub const MAX_IMAGE_SIZE: u32 = 1024 * 1024;

/// On-disk executable image header.
///
/// This structure occupies the first 16 bytes of every program image.
pub const BinHeader = extern struct {
    magic: u32,

    /// Binary format version.
    version: u16,

    /// Reserved for future use.
    /// Must be zero for version 1 images.
    flags: u16,

    /// Offset from the image base to the program entry point.
    entry_offset: u32,

    /// Total number of file-backed bytes emitted by the linker.
    image_size: u32,
};

comptime {
    // The loader assumes a fixed 16-byte header.
    std.debug.assert(@sizeOf(BinHeader) == 16);
}

/// Errors reported during binary image validation.
pub const Error = error{
    TooSmall,
    BadMagic,
    BadVersion,
    BadImageSize,
    BadEntry,
};

/// Validate the header fields only.
///
/// Requires only the first header-sized portion of the image, allowing
/// callers to verify an executable before reading the entire file.
///
/// Checks:
///   • magic value
///   • format version
///   • claimed image size
///
/// Does not validate the entry point because the full image may not
/// yet be available.
pub fn readHeader(bytes: []const u8) Error!BinHeader {
    if (bytes.len < @sizeOf(BinHeader))
        return error.TooSmall;

    const h = std.mem.bytesToValue(
        BinHeader,
        bytes[0..@sizeOf(BinHeader)],
    );

    if (h.magic != MAGIC)
        return error.BadMagic;

    if (h.version != VERSION)
        return error.BadVersion;

    if (h.image_size < @sizeOf(BinHeader) or
        h.image_size > MAX_IMAGE_SIZE)
        return error.BadImageSize;

    return h;
}

/// Perform full validation of a loaded program image.
///
/// Extends readHeader() by validating information that requires the
/// complete image buffer to be available.
///
/// Used by cmd_spawn before execution.
///
/// Additional checks:
///   • image_size does not exceed the loaded image size
///   • entry_offset lies within the image and beyond the header
pub fn parse(image: []const u8) Error!BinHeader {
    const h = try readHeader(image);

    // Reject images that claim more data than was actually loaded.
    if (h.image_size > image.len)
        return error.BadImageSize;

    // Ensure the entry point lies within the executable image and does
    // not point back into the header itself.
    if (h.entry_offset < @sizeOf(BinHeader) or
        h.entry_offset >= h.image_size)
        return error.BadEntry;

    return h;
}
