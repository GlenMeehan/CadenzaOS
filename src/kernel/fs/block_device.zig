//src/kernel/fs/block_device.zig

pub const BlockDeviceError = error{
    OutOfRange,
    IoError,
};

pub const BlockDevice = struct {
    /// Size of a single block in bytes (e.g. 512, 4096).
    block_size: usize,

    /// Total number of addressable blocks on this device.
    total_blocks: u64,

    /// Opaque context pointer for the concrete implementation (e.g. RamDisk, ATA disk, etc.).
    ctx: *anyopaque,

    /// Read one or more whole blocks starting at `lba` into `buf`.
    /// `buf.len` must be a multiple of `block_size`.
    readBlocks: *const fn (ctx: *anyopaque, lba: u64, buf: []u8) BlockDeviceError!void,

    /// Write one or more whole blocks starting at `lba` from `buf`.
    /// `buf.len` must be a multiple of `block_size`.
    writeBlocks: *const fn (ctx: *anyopaque, lba: u64, buf: []const u8) BlockDeviceError!void,
};

pub fn blockCount(dev: *const BlockDevice) u64 {
    return dev.total_blocks;
}

pub fn read(self: BlockDevice, lba: u64, buf: []u8) !void {
    if (buf.len % self.block_size != 0) return error.InvalidBufferSize;
    return self.readBlocks(self.ctx, lba, buf);
}
