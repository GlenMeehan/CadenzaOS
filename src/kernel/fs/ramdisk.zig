// src/kernel/fs/ramdisk.zig

const BlockDevice = @import("block_device.zig").BlockDevice;
const mem = @import("../memory.zig");

pub const RamDisk = struct {
    buffer: []u8,
    block_size: usize,

    pub fn init(buffer: []u8, block_size: usize) RamDisk {
        return RamDisk{
            .buffer = buffer,
            .block_size = block_size,
        };
    }

    pub fn readBlocksImpl(self: *RamDisk, lba: u64, out: []u8) !void {
        const start = lba * self.block_size;
        const end = start + out.len;

        if (end > self.buffer.len)
            return error.OutOfRange;

        // Convert slices to raw pointers
        const dst: [*]u8 = @ptrCast(out.ptr);
        const src: [*]const u8 = @ptrCast(self.buffer[start..end].ptr);

        // Copy bytes
        _ = mem.memcpy(dst, src, out.len);
    }

    pub fn writeBlocksImpl(self: *RamDisk, lba: u64, data: []const u8) !void {
        const start = lba * self.block_size;
        const end = start + data.len;

        if (end > self.buffer.len)
            return error.OutOfRange;

        // Convert slices to raw pointers
        const dst: [*]u8 = @ptrCast(self.buffer[start..end].ptr);
        const src: [*]const u8 = @ptrCast(data.ptr);

        // Copy bytes
        _ = mem.memcpy(dst, src, data.len);
    }

    pub fn asBlockDevice(self: *RamDisk) BlockDevice {
        return BlockDevice{
            .block_size = self.block_size,
            .total_blocks = self.buffer.len / self.block_size,
        };
    }
};
