// src/kernel/fs/coda_file.zig

const Extent = @import("coda_sm.zig").Extent;

pub const MAX_EXTENTS: usize = 8;
pub const MAX_NAME: usize = 64;

pub const FileType = enum {
    File,
    Directory,
};

pub const FileMeta = struct {
    file_type: FileType,
    size_bytes: u64,
    extent_count: u32,
    extents: [MAX_EXTENTS]Extent,
};

// *** THIS WAS MISSING ***
pub const DirEntry = struct {
    name: [MAX_NAME]u8,
    name_len: u8,
    meta_extent: Extent,
};

pub const Directory = struct {
    entries: []DirEntry,

    pub fn lookup(self: *Directory, name: []const u8) ?DirEntry {
        _ = self;
        _ = name;
        return null;
    }

    pub fn addEntry(self: *Directory, entry: DirEntry) !void {
        for (self.entries) |*e| {
            // Look for an empty slot (name_len == 0)
            if (e.name_len == 0) {
                e.* = entry;
                return;
            }
        }
        return error.DirectoryFull;
    }

    pub fn removeEntry(self: *Directory, name: []const u8) !void {
        _ = self;
        _ = name;
        return error.NotImplemented;
    }
};
