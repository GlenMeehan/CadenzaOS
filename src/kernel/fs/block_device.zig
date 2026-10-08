// src/kernel/fs/block_device.zig
//
// Generic block device abstraction.
//
// The filesystem never communicates directly with ATA, RAM disks,
// NVMe devices, or other storage implementations. Instead, every
// backend exposes a common BlockDevice interface.
//
// A BlockDevice guarantees:
//   • fixed-size addressable blocks
//   • block-aligned read/write operations
//   • a small, stable error surface
//
// This keeps filesystem code simple, portable, and backend-agnostic.

pub const BlockDeviceError = error{
    OutOfRange,   // Requested LBA lies outside the device address space
    IoError,      // Backend read/write operation failed
};

pub const BlockDevice = struct {

    /// Size of a single logical block in bytes.
    ///
    /// Filesystems assume this value remains constant for the lifetime
    /// of the device instance.
    block_size: usize,

    /// Total number of addressable blocks.
    ///
    /// Valid block indices are:
    ///     0 ..< total_blocks
    total_blocks: u64,

    /// Opaque pointer to backend-specific state.
    ///
    /// The concrete storage implementation owns and interprets this
    /// pointer (ATA device, RAM disk, NVMe controller, etc.).
    ctx: *anyopaque,

    /// Backend-provided block read implementation.
    ///
    /// The backend must honour block_size and read complete blocks.
    /// Callers are expected to provide a buffer whose length is a
    /// multiple of block_size.
    readBlocks: *const fn (
        ctx: *anyopaque,
        lba: u64,
        buf: []u8,
    ) BlockDeviceError!void,

    /// Backend-provided block write implementation.
    ///
    /// The backend must honour block_size and write complete blocks.
    /// Callers are expected to provide a buffer whose length is a
    /// multiple of block_size.
    writeBlocks: *const fn (
        ctx: *anyopaque,
        lba: u64,
        buf: []const u8,
    ) BlockDeviceError!void,
};

/// Convenience helper returning the device capacity in blocks.
pub fn blockCount(dev: *const BlockDevice) u64 {
    return dev.total_blocks;
}

/// High-level read wrapper.
///
/// Enforces interface invariants before delegating the request to the
/// underlying storage backend.
pub fn read(self: BlockDevice, lba: u64, buf: []u8) !void {

    // Enforce block alignment at the abstraction boundary.
    if (buf.len % self.block_size != 0)
        return error.InvalidBufferSize;

    // Delegate the actual I/O operation to the backend.
    return self.readBlocks(self.ctx, lba, buf);
}
