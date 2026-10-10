// src/kernel/globals.zig
//
// Centralised kernel-wide runtime state.
//
// This module provides globally accessible references to core kernel
// services that are initialised during boot and used throughout the
// system lifetime.
//
const CodaFs = @import("fs/coda_fs.zig").CodaFs;
const std = @import("std");

// -----------------------------------------------------------------------------
//  GLOBAL KERNEL SERVICES
// -----------------------------------------------------------------------------

/// Global filesystem instance.
///
/// Set during kernel initialisation after the filesystem has been
/// mounted and remains valid for the lifetime of the kernel.
pub var fs_global: *CodaFs = undefined;

/// Global kernel allocator.
///
/// Initialised during early boot and used by subsystems that require
/// dynamic memory allocation. Must be assigned before any allocation
/// attempts are made.
pub var kernel_allocator: std.mem.Allocator = undefined;
