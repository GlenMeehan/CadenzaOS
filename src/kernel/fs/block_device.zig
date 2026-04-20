// src/kernel/fs/block_device.zig
//
// Generic block device abstraction.
// The filesystem never talks directly to ATA, RAM disks, NVMe, etc.
// Instead, every storage backend implements this interface.
//
// A BlockDevice guarantees:
//   • fixed-size blocks (e.g. 512 bytes)
//   • block-aligned reads/writes
//   • a stable, minimal error surface
//
// This keeps the filesystem simple and backend‑agnostic.

pub const BlockDeviceError = error{
    OutOfRange,   // LBA outside device bounds
    IoError,      // Backend read/write failure
};

pub const BlockDevice = struct {
    /// Size of a single block in bytes.
    /// Filesystems assume this is constant for the lifetime of the device.
    block_size: usize,

    /// Total number of addressable blocks.
    /// The filesystem must not read/write beyond this.
    total_blocks: u64,

    /// Opaque pointer to the concrete implementation (ATA, RAM disk, etc.).
    /// The backend decides what this points to.
    ctx: *anyopaque,

    /// Backend-provided read function.
    /// Must read whole blocks: buf.len % block_size == 0.
    readBlocks: *const fn (ctx: *anyopaque, lba: u64, buf: []u8)
    BlockDeviceError!void,

    /// Backend-provided write function.
    /// Must write whole blocks: buf.len % block_size == 0.
    writeBlocks: *const fn (ctx: *anyopaque, lba: u64, buf: []const u8)
    BlockDeviceError!void,
};

/// Convenience: return total block count.
pub fn blockCount(dev: *const BlockDevice) u64 {
    return dev.total_blocks;
}

/// High-level read wrapper.
/// Performs invariant checks before calling backend.
pub fn read(self: BlockDevice, lba: u64, buf: []u8) !void {
    // Enforce block alignment at the interface boundary.
    if (buf.len % self.block_size != 0)
        return error.InvalidBufferSize;

    // Delegate to backend.
    return self.readBlocks(self.ctx, lba, buf);
}
