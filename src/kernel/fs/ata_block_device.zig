// src/kernel/fs/ata_block_device.zig
const BlockDevice = @import("block_device.zig").BlockDevice;
const BlockDeviceError = @import("block_device.zig").BlockDeviceError;
const ata = @import("../drivers/ata.zig");
const vga = @import("../vga.zig");

pub const AtaBlockDevice = struct {
    // We can keep track of the starting sector of our partition here
    partition_start: u64,

    pub fn init(start_lba: u64) AtaBlockDevice {
        return AtaBlockDevice{
            .partition_start = start_lba,
        };
    }

    /// This is the "Plug" that connects to your CodaFs "Socket"
    pub fn asBlockDevice(self: *AtaBlockDevice) BlockDevice {
        return BlockDevice{
            .ctx = self,
            .block_size = 512,
            .total_blocks = 20480, // Match what you used in format
            .readBlocks = readAdapter,
            .writeBlocks = writeAdapter,
        };
    }

    // This adapter translates the generic BlockDevice call to your specific ATA logic
    fn readAdapter(ctx: *anyopaque, block_lba: u64, buf: []u8) anyerror!void {
        const self: *AtaBlockDevice = @ptrCast(@alignCast(ctx));
        // Offset the read by our partition start
        const actual_lba = self.partition_start + block_lba;
        try ata.AtaDevice.readBlocks(null, actual_lba, buf);
    }

    fn writeAdapter(ctx: *anyopaque, block_lba: u64, buf: []const u8) anyerror!void {
        const self: *AtaBlockDevice = @ptrCast(@alignCast(ctx));
        // Offset the write by our partition start
        const actual_lba = self.partition_start + block_lba;
        try ata.AtaDevice.writeBlocks(null, actual_lba, buf);
    }
};
