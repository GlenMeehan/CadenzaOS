// src/kernel/fs/ramdisk.zig

const BlockDevice = @import("block_device.zig").BlockDevice;
const mem = @import("../memory.zig");
const ata = @import("../drivers/ata.zig"); // Import your driver

const partition_start = 2048; // Your partition offset

pub const RamDisk = struct {
    buffer: []u8,
    block_size: usize,

    pub fn init(buffer: []u8, block_size: usize) RamDisk {
        return RamDisk{
            .buffer = buffer,
            .block_size = block_size,
        };
    }

    pub fn readBlocksImpl(ctx: *anyopaque, lba: u64, out: []u8) !void {
        const self: *RamDisk = @ptrCast(@alignCast(ctx));

        const start = lba * self.block_size;
        const end = start + out.len;

        if (end > self.buffer.len)
            return error.OutOfRange;

        const dst: [*]u8 = @ptrCast(out.ptr);
        const src: [*]const u8 = @ptrCast(self.buffer[start..end].ptr);

        _ = mem.memcpy(dst, src, out.len);
    }


    pub fn asBlockDevice(self: *RamDisk) BlockDevice {
        return BlockDevice{
            .block_size = self.block_size,
            .total_blocks = self.buffer.len / self.block_size,
            .ctx = self,
            .readBlocks = RamDisk.readBlocksImpl,
            .writeBlocks = RamDisk.writeBlocksImpl,
        };
    }
    // Inside src/kernel/fs/ramdisk.zig

    fn writeBlocksImpl(ctx: *anyopaque, lba: u64, buf: []const u8) error{IoError, OutOfRange}!void {
        const self: *RamDisk = @ptrCast(@alignCast(ctx));
        const b_size: u64 = @intCast(self.block_size);
        const offset = lba * b_size;
        const end = offset + @as(u64, buf.len);

        if (end > self.buffer.len) return error.OutOfRange;

        // 1. Update the RAM Buffer (The Workspace)
        @memcpy(self.buffer[@intCast(offset)..@intCast(end)], buf);

        // 2. Immediately Update the Physical Disk (The Archive)
        // We use the driver directly to bypass the BlockDevice interface overhead
        ata.AtaDevice.writeBlocks(null, partition_start + lba, buf) catch {
            return error.IoError;
        };
    }
};


