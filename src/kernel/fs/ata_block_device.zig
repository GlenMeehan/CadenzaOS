// src/kernel/fs/ata_block_device.zig
const BlockDevice = @import("block_device.zig").BlockDevice;
const BlockDeviceError = @import("block_device.zig").BlockDeviceError;
const ata = @import("../drivers/ata.zig");
const vga = @import("../vga.zig");
const std = @import("std");
const conv = @import("../convert.zig");

const DeviceError = error{ IoError, OutOfRange };

pub const AtaBlockDevice = struct {
    partition_start: u64,

    pub fn init(start_lba: u64) AtaBlockDevice {
        return AtaBlockDevice{ .partition_start = start_lba };
    }

    pub fn asBlockDevice(self: *AtaBlockDevice) BlockDevice {
        return BlockDevice{
            .ctx = self,
            .block_size = 512,
            .total_blocks = 20480,
            .readBlocks = readAdapter,
            .writeBlocks = writeAdapter,
        };
    }

    // CHANGE: Use 'DeviceError!void' instead of 'anyerror!void'
    fn readAdapter(ctx: *anyopaque, block_lba: u64, buf: []u8) DeviceError!void {
        const self: *AtaBlockDevice = @ptrCast(@alignCast(ctx));
        const actual_lba = self.partition_start + block_lba;
        // Use 'catch' to map any unknown errors to our allowed IoError
        ata.AtaDevice.readBlocks(null, actual_lba, buf) catch return DeviceError.IoError;
    }

    // CHANGE: Use 'DeviceError!void' instead of 'anyerror!void'
    fn writeAdapter(ctx: *anyopaque, block_lba: u64, buf: []const u8) DeviceError!void {
        const self: *AtaBlockDevice = @ptrCast(@alignCast(ctx));
        const actual_lba = self.partition_start + block_lba;

        if (buf.len < 512) {
            // Create a temporary 512-byte buffer
            var temp_buf = std.mem.zeroes([512]u8);
            // Copy the small header into the start of the buffer
            @memcpy(temp_buf[0..buf.len], buf);
            // Write the full 512 bytes
            return ata.AtaDevice.writeBlocks(null, actual_lba, &temp_buf);
        }
        return ata.AtaDevice.writeBlocks(null, actual_lba, buf);
    }
};
