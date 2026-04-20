// src/kernel/fs/ramdisk.zig
//
// RAM Disk — Block Device Backed by a Memory Buffer
// --------------------------------------------------
// Implements a BlockDevice using a plain byte slice as backing store.
// Reads operate directly on the in-memory buffer.
//
// Writes are dual-path:
//   1. Update the in-memory buffer (the live workspace)
//   2. Write-through to the physical ATA disk (persistence across reboots)
//
// The ATA write uses a global partition offset (partition_start) so that
// logical LBA 0 maps to the correct physical sector on disk.
// ctx is unused — ATA access goes through the global AtaDevice interface.
//
// Usage:
//   var rd  = RamDisk.init(buffer, block_size);
//   var dev = rd.asBlockDevice();   // pass &dev to CodaFs.mount() / mkfs()

const BlockDevice = @import("block_device.zig").BlockDevice;
const mem         = @import("../memory.zig");
const ata         = @import("../drivers/ata.zig");

const partition_start = 2048;  // Physical LBA offset of the CODA partition on disk

// --------------------------------
// RamDisk
// --------------------------------

pub const RamDisk = struct {
    buffer:     []u8,
    block_size: usize,

    // ----------------------------------------------------------------
    // Initialisation
    // ----------------------------------------------------------------

    /// Wrap an existing byte slice as a RAM disk.
    /// `buffer` must remain valid for the lifetime of this RamDisk.
    /// `block_size` must divide evenly into `buffer.len`.
    pub fn init(buffer: []u8, block_size: usize) RamDisk {
        return RamDisk{
            .buffer     = buffer,
            .block_size = block_size,
        };
    }

    /// Return a BlockDevice interface backed by this RamDisk.
    /// The returned BlockDevice holds a pointer to `self`, so `self`
    /// must not be moved or freed while the BlockDevice is in use.
    pub fn asBlockDevice(self: *RamDisk) BlockDevice {
        return BlockDevice{
            .block_size   = self.block_size,
            .total_blocks = self.buffer.len / self.block_size,
            .ctx          = self,
            .readBlocks   = RamDisk.readBlocksImpl,
            .writeBlocks  = RamDisk.writeBlocksImpl,
        };
    }

    // ----------------------------------------------------------------
    // BlockDevice callbacks
    // ----------------------------------------------------------------

    /// Read `out.len` bytes starting at `lba` from the in-memory buffer.
    /// `out` must be a multiple of `block_size` in length.
    pub fn readBlocksImpl(ctx: *anyopaque, lba: u64, out: []u8) !void {
        const self: *RamDisk = @ptrCast(@alignCast(ctx));
        const start = lba * self.block_size;
        const end   = start + out.len;

        if (end > self.buffer.len) return error.OutOfRange;

        const dst: [*]u8       = @ptrCast(out.ptr);
        const src: [*]const u8 = @ptrCast(self.buffer[start..end].ptr);
        _ = mem.memcpy(dst, src, out.len);
    }

    /// Write `buf` to the in-memory buffer at the offset for `lba`,
    /// then write-through to the physical ATA disk for persistence across reboots.
    /// `buf` must be a multiple of `block_size` in length.
    fn writeBlocksImpl(ctx: *anyopaque, lba: u64, buf: []const u8) error{ IoError, OutOfRange }!void {
        const self: *RamDisk = @ptrCast(@alignCast(ctx));
        const b_size: u64    = @intCast(self.block_size);
        const offset         = lba * b_size;
        const end            = offset + @as(u64, buf.len);

        if (end > self.buffer.len) return error.OutOfRange;

        // 1. Update the RAM buffer (live workspace)
        @memcpy(self.buffer[@intCast(offset)..@intCast(end)], buf);

        // 2. Write-through to physical disk (persistence across reboots)
        ata.AtaDevice.writeBlocks(null, partition_start + lba, buf) catch {
            return error.IoError;
        };
    }
};
