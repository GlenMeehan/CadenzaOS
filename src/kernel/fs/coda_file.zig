// src/kernel/fs/coda_file.zig
//
// Core on‑disk structures for the Coda filesystem.
// These structs define:
//   • File metadata (type, size, extents)
//   • Directory entries
//   • In‑memory directory view + lookup/insert/rename
//
// IMPORTANT:
//   These structs are written to disk *verbatim* using @sizeOf().
//   Any layout change is a breaking on‑disk format change.
//   Keep fields stable and aligned.

const Extent = @import("coda_sm.zig").Extent;
const std = @import("std");

pub const MAX_EXTENTS: usize = 8;   // Max extents per file (fixed-size array)
pub const MAX_NAME: usize = 64;     // Max filename length (bytes)

/// Type of file represented by FileMeta.
pub const FileType = enum(u8) {
    File,
    Directory,
};

/// On‑disk file metadata block.
/// Written directly to disk via writeBlockStruct().
///
/// Layout:
///   file_type      — File or Directory
///   size_bytes     — Logical file size
///   extent_count   — Number of valid extents in `extents`
///   extents[]      — Up to MAX_EXTENTS physical extents
///
/// NOTE:
///   This struct must remain stable. Changing field order or size
///   breaks compatibility with existing disks.
pub const FileMeta = extern struct {
    file_type: FileType,
    size_bytes: u64,
    extent_count: u32,
    extents: [MAX_EXTENTS]Extent,
};

/// A single directory entry stored inside a directory block.
///
/// name[]     — Fixed-size buffer; only first name_len bytes are valid
/// name_len   — Actual length of the filename
/// meta_extent — The extent where the file's FileMeta is stored
///
/// NOTE:
///   This struct is also written to disk verbatim.
pub const DirEntry = struct {
    name: [MAX_NAME]u8,
    name_len: u8,
    meta_extent: Extent,
};

/// In‑memory view of a directory block.
/// `entries` is a slice pointing into a block-sized buffer.
///
/// The directory block is a flat array of DirEntry structs.
/// Empty entries are indicated by name_len == 0.
pub const Directory = struct {
    entries: []DirEntry,

    /// Look up a directory entry by name.
    /// Returns a pointer into the entries slice, or null.
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

    /// Rename an existing entry.
    /// Ensures:
    ///   • old_name exists
    ///   • new_name does not collide
    ///   • new_name fits in MAX_NAME
    pub fn renameEntry(self: *Directory, old_name: []const u8, new_name: []const u8) !void {
        const entry = self.lookup(old_name) orelse return error.FileNotFound;

        if (self.lookup(new_name) != null)
            return error.NameAlreadyExists;

        if (new_name.len > MAX_NAME)
            return error.NameTooLong;

        @memset(&entry.name, 0);
        @memcpy(entry.name[0..new_name.len], new_name);
        entry.name_len = @intCast(new_name.len);
    }

    /// Insert a new directory entry into the first free slot.
    /// A free slot is defined as name_len == 0.
    pub fn addEntry(self: *Directory, entry: DirEntry) !void {
        for (self.entries) |*e| {
            if (e.name_len == 0) {
                e.* = entry;
                return;
            }
        }
        return error.DirectoryFull;
    }

    /// Remove a directory entry (not implemented yet).
    /// Will eventually zero out the entry and mark it free.
    pub fn removeEntry(self: *Directory, name: []const u8) !void {
        _ = self;
        _ = name;
        return error.NotImplemented;
    }
};
