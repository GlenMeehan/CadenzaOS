// src/kernel/fs/ramdisk.zig
//
// RAM Disk — Block Device Backed by a Memory Buffer
// -------------------------------------------------
// Implements a BlockDevice using a memory-resident byte buffer as the
// primary backing store.
//
// Reads are serviced entirely from RAM.
//
// Writes follow a write-through model:
//   1. Update the in-memory buffer (live working state)
//   2. Persist the same data to the underlying ATA device
//
// The ATA write uses the configured partition offset so that logical
// block 0 maps to the correct physical disk location.
//
// The BlockDevice ctx parameter references the RamDisk instance.
// ATA access itself is performed through the global AtaDevice interface.
//
// Usage:
//   var rd  = RamDisk.init(buffer, block_size);
//   var dev = rd.asBlockDevice();
//   // pass &dev to CodaFs.mount() / mkfs()

const BlockDevice = @import("block_device.zig").BlockDevice;
const mem         = @import("../memory.zig");
const ata         = @import("../drivers/ata.zig");
const conf = @import("../config.zig");

/// Physical disk LBA corresponding to logical block 0 of the filesystem.
const partition_start = conf.PARTITION_START_LBA;

// --------------------------------
// RamDisk
// --------------------------------

pub const RamDisk = struct {
    buffer:     []u8,
    block_size: usize,

    // ----------------------------------------------------------------
    // Initialisation
    // ----------------------------------------------------------------

    /// Wrap an existing memory buffer as a RamDisk.
    ///
    /// Requirements:
    ///   • buffer must remain valid for the lifetime of the RamDisk
    ///   • block_size must divide evenly into buffer.len
    pub fn init(buffer: []u8, block_size: usize) RamDisk {
        return RamDisk{
            .buffer     = buffer,
            .block_size = block_size,
        };
    }

    /// Return a BlockDevice interface backed by this RamDisk.
    ///
    /// The returned BlockDevice stores a pointer to `self`, so the
    /// RamDisk instance must remain valid while the interface is in use.
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

    /// Read one or more blocks beginning at `lba` from the in-memory
    /// backing buffer.
    ///
    /// `out.len` must describe a whole number of blocks.
    pub fn readBlocksImpl(ctx: *anyopaque, lba: u64, out: []u8) !void {
        const self: *RamDisk = @ptrCast(@alignCast(ctx));

        const start = lba * self.block_size;
        const end   = start + out.len;

        if (end > self.buffer.len)
            return error.OutOfRange;

        const dst: [*]u8       = @ptrCast(out.ptr);
        const src: [*]const u8 = @ptrCast(self.buffer[start..end].ptr);

        _ = mem.memcpy(dst, src, out.len);
    }

    /// Write blocks to the RamDisk and immediately persist them to the
    /// backing ATA partition.
    ///
    /// This provides fast RAM-backed access while ensuring modifications
    /// survive reboot via write-through persistence.
    ///
    /// `buf.len` must describe a whole number of blocks.
    fn writeBlocksImpl(
        ctx: *anyopaque,
        lba: u64,
        buf: []const u8,
    ) error{ IoError, OutOfRange }!void {
        const self: *RamDisk = @ptrCast(@alignCast(ctx));

        const b_size: u64 = @intCast(self.block_size);
        const offset      = lba * b_size;
        const end         = offset + @as(u64, buf.len);

        if (end > self.buffer.len)
            return error.OutOfRange;

        // 1. Update the in-memory copy.
        @memcpy(
            self.buffer[@intCast(offset)..@intCast(end)],
                buf,
        );

        // 2. Write-through to the physical disk image.
        //    Logical filesystem block N becomes:
        //        partition_start + N
        ata.AtaDevice.writeBlocks(
            null,
            partition_start + lba,
            buf,
        ) catch {
            return error.IoError;
        };
    }
};
