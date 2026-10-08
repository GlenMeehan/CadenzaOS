// src/kernel/fs/coda_file.zig
//
// Core on-disk structures for the Coda filesystem.
//
// These structs define:
//   • File metadata (type, size, extents)
//   • Directory entries
//   • In-memory directory view and common directory operations
//
// IMPORTANT:
//   These structures are written to disk largely verbatim.
//   Their layout forms part of the on-disk filesystem format.
//   Any change to field order, size, alignment, or representation
//   may break compatibility with existing filesystem images.

const Extent = @import("coda_sm.zig").Extent;
const std = @import("std");

pub const MAX_EXTENTS: usize = 8;   // Maximum extents tracked per file
pub const MAX_NAME: usize = 64;     // Maximum filename length in bytes

/// Type of object represented by a FileMeta record.
pub const FileType = enum(u8) {
    File,
    Directory,
};

/// On-disk file metadata record.
///
/// Written directly to disk and read back without translation.
///
/// Layout:
///   file_type      — File or Directory
///   size_bytes     — Logical file size in bytes
///   extent_count   — Number of valid entries in `extents`
///   extents[]      — Physical storage extents for file data
///
/// NOTE:
///   This structure is part of the filesystem format.
///   Changing field order, size, alignment, or enum representation
///   breaks compatibility with existing disks.
pub const FileMeta = extern struct {
    file_type: FileType,
    size_bytes: u64,
    extent_count: u32,
    extents: [MAX_EXTENTS]Extent,
};

/// A single directory entry stored within a directory block.
///
/// name[]      — Fixed-size filename buffer
/// name_len    — Number of valid bytes in `name`
/// meta_extent — Extent containing the file's FileMeta record
///
/// Only the first `name_len` bytes of `name` are considered valid.
///
/// NOTE:
///   This structure is also stored on disk and should be treated
///   as part of the filesystem format.
pub const DirEntry = struct {
    name: [MAX_NAME]u8,
    name_len: u8,
    meta_extent: Extent,
};

/// In-memory view of a directory block.
///
/// `entries` points into a block-sized buffer containing a flat array
/// of DirEntry records.
///
/// An entry with `name_len == 0` is considered unused and available
/// for allocation.
pub const Directory = struct {
    entries: []DirEntry,

    /// Look up a directory entry by name.
    ///
    /// Returns a pointer into the underlying entries array,
    /// or null if the entry does not exist.
    pub fn lookup(self: *Directory, name: []const u8) ?*DirEntry {
        for (self.entries) |*e| {
            if (e.name_len == name.len) {
                if (std.mem.eql(u8, e.name[0..e.name_len], name)) {
                    return e;
                }
            }
        }

        return null;
    }

    /// Rename an existing directory entry.
    ///
    /// Ensures:
    ///   • old_name exists
    ///   • new_name does not already exist
    ///   • new_name fits within MAX_NAME
    ///
    /// Only the directory entry is updated. The underlying FileMeta
    /// record remains unchanged.
    pub fn renameEntry(
        self: *Directory,
        old_name: []const u8,
        new_name: []const u8,
    ) !void {
        const entry = self.lookup(old_name)
        orelse return error.FileNotFound;

        if (self.lookup(new_name) != null)
            return error.NameAlreadyExists;

        if (new_name.len > MAX_NAME)
            return error.NameTooLong;

        @memset(&entry.name, 0);
        @memcpy(entry.name[0..new_name.len], new_name);
        entry.name_len = @intCast(new_name.len);
    }

    /// Insert a new directory entry into the first available slot.
    ///
    /// A free slot is identified by `name_len == 0`.
    ///
    /// Returns DirectoryFull if the directory block contains
    /// no unused entries.
    pub fn addEntry(self: *Directory, entry: DirEntry) !void {
        for (self.entries) |*e| {
            if (e.name_len == 0) {
                e.* = entry;
                return;
            }
        }

        return error.DirectoryFull;
    }

    /// Remove a directory entry.
    ///
    /// Not implemented yet.
    ///
    /// The intended implementation is to clear the entry and mark
    /// the slot available for reuse while leaving any associated
    /// file cleanup to higher-level filesystem code.
    pub fn removeEntry(self: *Directory, name: []const u8) !void {
        _ = self;
        _ = name;

        return error.NotImplemented;
    }
};
