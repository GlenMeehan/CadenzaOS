//src/kernel/fs/block_device.zig

pub const BlockDevice = struct {
    // Size of a single block in bytes (e.g. 512, 4096).
    block_size: usize,

    // Total number of addressable blocks on this device.
    total_blocks: u64,

    // Read one or more whole blocks starting at `lba` into `buf`.
    // `buf.len` must be a multiple of `block_size`.
    //readBlocks: fn (lba: u64, buf: []u8) BlockDeviceError!void,

    // Write one or more whole blocks starting at `lba` from `buf`.
    // `buf.len` must be a multiple of `block_size`.
    //writeBlocks: fn (lba: u64, buf: []const u8) BlockDeviceError!void,
};

pub const BlockDeviceError = error{
    OutOfRange,
    IoError,
};

