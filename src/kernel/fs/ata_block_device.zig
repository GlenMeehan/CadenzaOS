// src/kernel/fs/ata_block_device.zig
//
// Thin wrapper that adapts the ATA driver (drivers/ata.zig)
// into the generic BlockDevice interface used by the filesystem.
//
// Responsibilities:
//   • Translate filesystem LBAs → absolute disk LBAs
//   • Enforce filesystem block geometry
//   • Map ATA driver errors into a small, stable DeviceError set
//   • Provide read/write adapters matching the BlockDevice interface
//
// NOTE:
//   The filesystem operates in fixed-size blocks defined by
//   conf.BLOCK_SIZE. The ATA driver performs the actual sector I/O.

const BlockDevice = @import("block_device.zig").BlockDevice;
const BlockDeviceError = @import("block_device.zig").BlockDeviceError;
const ata = @import("../drivers/ata.zig");
const std = @import("std");
const conf = @import("../config.zig");

/// Errors exposed to the filesystem.
///
/// The ATA driver may expose additional implementation details internally,
/// but the filesystem only depends on this small, stable error set.
const DeviceError = error{
    IoError,      // ATA read/write operation failed
    OutOfRange,   // Reserved for future bounds checking
};

pub const AtaBlockDevice = struct {
    /// First LBA of the partition represented by this device.
    ///
    /// Filesystem block 0 maps to:
    ///     partition_start + 0
    partition_start: u64,

    /// Create a new ATA-backed block device rooted at `start_lba`.
    ///
    /// All filesystem block addresses are translated relative
    /// to this partition start offset.
    pub fn init(start_lba: u64) AtaBlockDevice {
        return AtaBlockDevice{
            .partition_start = start_lba,
        };
    }

    /// Convert this ATA-backed device into the generic BlockDevice
    /// interface used throughout the filesystem layer.
    ///
    /// Consumers interact only with BlockDevice and are unaware that
    /// ATA is the underlying storage implementation.
    pub fn asBlockDevice(self: *AtaBlockDevice) BlockDevice {
        return BlockDevice{
            .ctx = self,
            .block_size = conf.BLOCK_SIZE,
            .total_blocks = conf.DISK_SECTOR_COUNT, // TODO: detect from ATA IDENTIFY data
            .readBlocks = readAdapter,
            .writeBlocks = writeAdapter,
        };
    }

    // -------------------------------------------------------------------------
    // READ ADAPTER
    // -------------------------------------------------------------------------
    //
    // Converts filesystem block reads into ATA reads.
    // Filesystem-relative LBAs are translated into absolute disk LBAs.
    // ATA-specific errors are collapsed into DeviceError.IoError.
    //
    fn readAdapter(ctx: *anyopaque, block_lba: u64, buf: []u8) DeviceError!void {
        const self: *AtaBlockDevice = @ptrCast(@alignCast(ctx));

        // Translate filesystem LBA -> absolute disk LBA.
        const actual_lba = self.partition_start + block_lba;

        // The ATA layer may return implementation-specific errors.
        // Expose only a stable filesystem-facing error contract.
        ata.AtaDevice.readBlocks(null, actual_lba, buf)
        catch return DeviceError.IoError;
    }

    // -------------------------------------------------------------------------
    // WRITE ADAPTER
    // -------------------------------------------------------------------------
    //
    // Converts filesystem block writes into ATA writes.
    //
    // Some callers may provide less than one full block of data
    // (for example, small metadata structures). ATA writes operate
    // on complete sectors, so short writes are zero-padded.
    //
    fn writeAdapter(ctx: *anyopaque, block_lba: u64, buf: []const u8) DeviceError!void {
        const self: *AtaBlockDevice = @ptrCast(@alignCast(ctx));

        // Translate filesystem LBA -> absolute disk LBA.
        const actual_lba = self.partition_start + block_lba;

        // If the caller provides less than one full block,
        // create a temporary zero-padded sector.
        if (buf.len < conf.BLOCK_SIZE) {
            var temp_buf = std.mem.zeroes([conf.BLOCK_SIZE]u8);
            @memcpy(temp_buf[0..buf.len], buf);

            ata.AtaDevice.writeBlocks(null, actual_lba, &temp_buf)
            catch return DeviceError.IoError;

            return;
        }

        // Full-block write path.
        ata.AtaDevice.writeBlocks(null, actual_lba, buf)
        catch return DeviceError.IoError;
    }
};
