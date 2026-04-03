// src/kernel/fs/coda_file.zig

const Extent = @import("coda_sm.zig").Extent;
const std = @import("std");

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

    pub fn lookup(self: *Directory, name: []const u8) ?*DirEntry {
        for (self.entries) |*e| {
            // Check if lengths match first for speed
            if (e.name_len == name.len) {
                // Compare only the active part of the name buffer
                if (std.mem.eql(u8, e.name[0..e.name_len], name)) {
                    return e;
                }
            }
        }
        return null;
    }

    pub fn renameEntry(self: *Directory, old_name: []const u8, new_name: []const u8) !void {
        // 1. Find the existing entry
        const entry = self.lookup(old_name) orelse return error.FileNotFound;

        // 2. Collision Check: Ensure the new name isn't already taken
        if (self.lookup(new_name) != null) {
            return error.NameAlreadyExists;
        }

        // 3. Validate new name length
        if (new_name.len > MAX_NAME) return error.NameTooLong;

        // 4. Perform the swap
        @memset(&entry.name, 0);
        @memcpy(entry.name[0..new_name.len], new_name);
        entry.name_len = @intCast(new_name.len);
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
