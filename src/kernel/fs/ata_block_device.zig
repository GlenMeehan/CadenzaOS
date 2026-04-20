// src/kernel/fs/ata_block_device.zig
//
// Thin wrapper that adapts the ATA driver (drivers/ata.zig)
// into the generic BlockDevice interface used by the filesystem.
//
// Responsibilities:
//   • Translate filesystem LBAs → absolute disk LBAs
//   • Enforce 512‑byte block size
//   • Map ATA driver errors into a small, stable DeviceError set
//   • Provide read/write adapters matching BlockDevice signature
//
// NOTE:
//   The filesystem always works in 512‑byte blocks.
//   The ATA driver already guarantees 512‑byte sectors.

const BlockDevice = @import("block_device.zig").BlockDevice;
const BlockDeviceError = @import("block_device.zig").BlockDeviceError;
const ata = @import("../drivers/ata.zig");
const std = @import("std");

/// Errors exposed to the filesystem.
/// We intentionally keep this small and stable.
const DeviceError = error{
    IoError,      // ATA read/write failed
    OutOfRange,   // (reserved for future bounds checking)
};

pub const AtaBlockDevice = struct {
    /// First LBA of the partition this device represents.
    /// The filesystem sees block 0 → actual LBA = partition_start.
    partition_start: u64,

    /// Create a new ATA-backed block device starting at a given LBA.
    pub fn init(start_lba: u64) AtaBlockDevice {
        return AtaBlockDevice{
            .partition_start = start_lba,
        };
    }

    /// Convert this into a generic BlockDevice interface.
    /// The filesystem only sees this interface — not the ATA driver.
    pub fn asBlockDevice(self: *AtaBlockDevice) BlockDevice {
        return BlockDevice{
            .ctx = self,
            .block_size = 512,
            .total_blocks = 20480, // TODO: detect from ATA identify data
            .readBlocks = readAdapter,
            .writeBlocks = writeAdapter,
        };
    }

    // -------------------------------------------------------------------------
    // READ ADAPTER
    // -------------------------------------------------------------------------
    //
    // Converts filesystem block reads → ATA reads.
    // Maps all ATA errors into DeviceError.IoError.
    //
    fn readAdapter(ctx: *anyopaque, block_lba: u64, buf: []u8) DeviceError!void {
        const self: *AtaBlockDevice = @ptrCast(@alignCast(ctx));

        // Translate filesystem LBA → absolute disk LBA
        const actual_lba = self.partition_start + block_lba;

        // ATA driver returns anyerror, but we collapse it to IoError.
        ata.AtaDevice.readBlocks(null, actual_lba, buf)
        catch return DeviceError.IoError;
    }

    // -------------------------------------------------------------------------
    // WRITE ADAPTER
    // -------------------------------------------------------------------------
    //
    // The filesystem may write buffers smaller than 512 bytes (e.g. superblock
    // headers). ATA requires full 512-byte sectors, so we pad small writes.
    //
    fn writeAdapter(ctx: *anyopaque, block_lba: u64, buf: []const u8) DeviceError!void {
        const self: *AtaBlockDevice = @ptrCast(@alignCast(ctx));
        const actual_lba = self.partition_start + block_lba;

        // If the caller gives us less than 512 bytes, pad it.
        if (buf.len < 512) {
            var temp_buf = std.mem.zeroes([512]u8);
            @memcpy(temp_buf[0..buf.len], buf);

            ata.AtaDevice.writeBlocks(null, actual_lba, &temp_buf)
            catch return DeviceError.IoError;

            return;
        }

        // Normal 512-byte write
        ata.AtaDevice.writeBlocks(null, actual_lba, buf)
        catch return DeviceError.IoError;
    }
};
