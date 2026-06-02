// src/kernel/globals.zig
//
const CodaFs = @import("fs/coda_fs.zig").CodaFs;
const std = @import("std");
// ============================================================
// Runtime Kernel Globals
// ============================================================

/// Global filesystem instance.
///
/// Initialized during early kernel boot.
pub var fs_global: *CodaFs = undefined;

/// Global kernel allocator.
///
/// Must be initialized before dynamic allocation.
pub var kernel_allocator: std.mem.Allocator = undefined;


