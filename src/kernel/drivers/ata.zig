// src/kernel/drivers/ata.zig
//
// ATA PIO Driver
// --------------
// Bare-metal ATA (IDE) driver using Programmed I/O (PIO) mode.
// Provides synchronous block read and write operations against the
// primary ATA bus (I/O base 0x1F0) using ATA sectors as the underlying
// transfer unit.
//
// Limitations:
//   • PIO only — no DMA
//   • LBA28 addressing (max ~128 GiB)
//   • Single drive (primary master)
//   • No IRQ handling; all waits are busy-poll loops
//
// All public functions accept a nullable ctx pointer to satisfy the
// BlockDevice callback signature; ctx is unused (global port I/O).

const std       = @import("std");
const port      = @import("../port_io.zig");
const vga       = @import("../vga.zig");
const BlockDevice = @import("../fs/block_device.zig").BlockDevice;
const conf = @import("../config.zig");
const coda_fs = @import("../fs/coda_fs.zig");
const conv = @import("../convert.zig");


// --------------------------------
// ATA register ports
// --------------------------------

const ATA_DATA         = 0x1F0;  // 16-bit data register
const ATA_SECTOR_COUNT = 0x1F2;
const ATA_LBA_LOW      = 0x1F3;
const ATA_LBA_MID      = 0x1F4;
const ATA_LBA_HIGH     = 0x1F5;
const ATA_DRIVE_SELECT = 0x1F6;
const ATA_COMMAND      = 0x1F7;  // Write: command register
const ATA_STATUS       = 0x1F7;  // Read:  status register

// --------------------------------
// ATA commands
// --------------------------------

const CMD_READ_PIO  = 0x20;
const CMD_WRITE_PIO = 0x30;
const CMD_FLUSH     = 0xE7;  // Flush drive write cache to media

// --------------------------------
// Status register bit masks
// --------------------------------

const STATUS_BSY = 0x80;  // Drive busy
const STATUS_DRQ = 0x08;  // Data request — drive ready for transfer
const STATUS_ERR = 0x01;  // Error flag

// --------------------------------
// Error set
// --------------------------------

// ATA driver errors. IoError is returned for device status failures
// and timeout conditions encountered while polling the controller.
const DeviceError = error{ IoError, OutOfRange };

// --------------------------------
// AtaDevice
// --------------------------------

pub const AtaDevice = struct {

    /// Return a BlockDevice interface backed by this AtaDevice.
    ///
    /// Block geometry is defined by kernel configuration:
    ///   - block_size   = conf.BLOCK_SIZE
    ///   - total_blocks = conf.DISK_SECTOR_COUNT
    pub fn asBlockDevice(self: *AtaDevice) BlockDevice {
        return BlockDevice{
            .ctx          = self,
            .block_size   = conf.BLOCK_SIZE,
            .total_blocks = conf.DISK_SECTOR_COUNT,
            .readBlocks   = readBlocks,
            .writeBlocks  = writeBlocks,
        };
    }

    /// Probe whether a CODA filesystem exists at `lba`.
    ///
    /// Reads the first 8 bytes of the block and compares them against
    /// `coda_fs.CODA_MAGIC`.
    ///
    /// This helper predates the current CODA superblock validation logic
    /// and should not be treated as authoritative filesystem verification.
    pub fn checkFileSystem(lba: u32) bool {
        var buffer: [conf.BLOCK_SIZE]u8 align(8) = undefined;
        readBlocks(null, lba, &buffer) catch return false;

        const header = @as(*[conf.BLOCK_SIZE]u8, @ptrCast(@alignCast(&buffer)));
        const magic = std.mem.readInt(u64, header[0..8], .little);

        return magic == coda_fs.CODA_MAGIC;
    }
    // ----------------------------------------------------------------
    // BlockDevice callbacks
    // ----------------------------------------------------------------

    /// Read one or more sectors beginning at `lba` into `buf`.
    ///
    /// The transfer size is derived from `buf.len`, rounded up to the
    /// nearest sector. Reads are issued in chunks of up to 128 sectors
    /// to avoid ATA sector-count overflow.
    pub fn readBlocks(ctx: ?*anyopaque, lba: u64, buf: []u8) DeviceError!void {
        _ = ctx;

        var sectors_remaining = (buf.len + conf.BLOCK_SIZE - 1) / conf.BLOCK_SIZE;
        var current_lba       = lba;
        var current_offset: usize = 0;

        while (sectors_remaining > 0) {
            const sectors_to_read: u8 = if (sectors_remaining > 128)
            128
            else
                @as(u8, @truncate(sectors_remaining));

            // Select the primary master device in LBA mode and provide
            // the upper 4 bits of the 28-bit LBA address.
            port.outb(ATA_DRIVE_SELECT, @as(u8, @truncate(0xE0 | ((current_lba >> 24) & 0x0F))));
            io_delay();

            port.outb(ATA_SECTOR_COUNT, sectors_to_read);
            port.outb(ATA_LBA_LOW,  @as(u8, @truncate( current_lba        & 0xFF)));
            port.outb(ATA_LBA_MID,  @as(u8, @truncate((current_lba >>  8) & 0xFF)));
            port.outb(ATA_LBA_HIGH, @as(u8, @truncate((current_lba >> 16) & 0xFF)));
            port.outb(ATA_COMMAND, CMD_READ_PIO);

            var i: usize = 0;
            while (i < sectors_to_read) : (i += 1) {
                try wait_bsy();
                try wait_drq();

                // Read one 512-byte ATA sector as 256 16-bit words.
                var j: usize = 0;
                while (j < 256) : (j += 1) {
                    const data = port.inw(ATA_DATA);

                    if (current_offset     < buf.len) buf[current_offset]     = @as(u8, @truncate(data & 0xFF));
                    if (current_offset + 1 < buf.len) buf[current_offset + 1] = @as(u8, @truncate(data >> 8));

                    current_offset += 2;
                }
            }

            sectors_remaining -= sectors_to_read;
            current_lba       += sectors_to_read;
        }
    }

    /// Write one or more sectors from `buf` beginning at `lba`.
    ///
    /// For maximum hardware compatibility, writes are performed one
    /// sector at a time. A cache flush command is issued after each
    /// sector to ensure data reaches persistent media.
    pub fn writeBlocks(ctx: ?*anyopaque, lba: u64, buf: []const u8) DeviceError!void {
        _ = ctx;

        const total_sectors = @as(u32, @intCast((buf.len + conf.BLOCK_SIZE - 1) / conf.BLOCK_SIZE));
        if (total_sectors == 0) return;

        // Disable device interrupts via the control register.
        // This driver uses polling exclusively.
        port.outb(0x3F6, 0x02);

        var current_sector: u32 = 0;
        while (current_sector < total_sectors) : (current_sector += 1) {
            try wait_bsy();

            const current_lba = lba + current_sector;

            // 1. Select the primary master device and provide the upper
            //    4 bits of the LBA address.
            port.outb(ATA_DRIVE_SELECT, 0x40 | @as(u8, @intCast((current_lba >> 24) & 0x0F)));
            io_delay();

            // 2. Program a single-sector transfer.
            port.outb(ATA_SECTOR_COUNT, 1);
            port.outb(ATA_LBA_LOW,  @as(u8, @intCast( current_lba        & 0xFF)));
            port.outb(ATA_LBA_MID,  @as(u8, @intCast((current_lba >>  8) & 0xFF)));
            port.outb(ATA_LBA_HIGH, @as(u8, @intCast((current_lba >> 16) & 0xFF)));
            io_delay();

            // 3. Issue the PIO write command.
            port.outb(ATA_COMMAND, CMD_WRITE_PIO);
            io_delay();

            // 4. Wait for the drive to become ready to accept data.
            while (port.inb(ATA_STATUS) & STATUS_BSY != 0) {}

            const status = port.inb(ATA_STATUS);

            // Fail on ERR or DF (Device Fault).
            if ((status & (STATUS_ERR | (1 << 5))) != 0) return DeviceError.IoError;

            while ((port.inb(ATA_STATUS) & STATUS_DRQ) == 0) {}

            // 5. Transfer one sector (256 words / 512 bytes).
            //    Any partial final sector is padded with zeros.
            var j: usize = 0;
            while (j < 256) : (j += 1) {
                const offset = (current_sector * conf.BLOCK_SIZE) + (j * 2);

                const data: u16 = if (offset + 1 < buf.len)
                @as(u16, buf[offset]) | (@as(u16, buf[offset + 1]) << 8)
                else if (offset < buf.len)
                    @as(u16, buf[offset])
                    else
                        0;

                port.outw(ATA_DATA, data);
            }

            // 6. Read the status register once after the final data word
            //    is written, giving the device time to update status
            //    before the next command is issued.
            _ = port.inb(ATA_STATUS);

            // 7. Flush the drive write cache to guarantee persistence.
            port.outb(ATA_COMMAND, CMD_FLUSH);
            try wait_bsy();
        }
    }
};

// ----------------------------------------------------------------
// Top-level kernel helpers
// ----------------------------------------------------------------

/// Write a minimal partition table entry into MBR partition slot 1.
///
/// The existing MBR sector is read first so boot code is preserved.
/// Only the first partition entry is overwritten.
///
/// `start_lba`       — first sector of the partition
/// `size_in_sectors` — total sector count of the partition
pub fn initializePartitionTable(start_lba: u32, size_in_sectors: u32) void {
    var buffer: [conf.BLOCK_SIZE]u8 align(8) = undefined;

    AtaDevice.readBlocks(null, 0, &buffer) catch {
        vga.writeString("Error: Could not read MBR\n", 12, 0);
        return;
    };

    // Partition entry 1 begins at byte offset 446 within the MBR.
    const offset = 446;

    buffer[offset + 0] = 0x80;  // Active / bootable partition
    buffer[offset + 4] = 0x83;  // Linux native partition type

    std.mem.writeInt(u32, buffer[offset +  8..offset + 12], start_lba,       .little);
    std.mem.writeInt(u32, buffer[offset + 12..offset + 16], size_in_sectors, .little);

    // Standard MBR boot signature.
    buffer[510] = 0x55;
    buffer[511] = 0xAA;

    AtaDevice.writeBlocks(null, 0, &buffer) catch {
        vga.writeString("Error: Could not write MBR\n", 12, 0);
    };
}

/// Write a minimal legacy superblock to `lba`.
///
/// Writes a single-sector legacy superblock directly to disk.
///
/// WARNING: Uses the legacy magic value 0xDEAFBEEF and does not initialise
/// the SpaceManager region or root directory extent.
/// This predates CodaFs.mkfs() and should not be used for new filesystems.
/// Retained for historical reference only.
pub fn formatMyFileSystem(lba: u32) void {
    var buffer align(8) = std.mem.zeroes([conf.BLOCK_SIZE]u8);

    // TODO: Replace with CodaFs.mkfs().
    // This layout does not produce a valid modern CODA filesystem.
    std.mem.writeInt(u64, buffer[0..8],   0xDEAFBEEF, .little);          // Legacy magic
    std.mem.writeInt(u32, buffer[8..12],  1, .little);                   // Version
    std.mem.writeInt(u32, buffer[12..16], conf.BLOCK_SIZE, .little);     // Block size
    std.mem.writeInt(u64, buffer[16..24], conf.DISK_SECTOR_COUNT, .little); // Total blocks

    AtaDevice.writeBlocks(null, @as(u64, lba), &buffer) catch {};
}

// ----------------------------------------------------------------
// Private helpers
// ----------------------------------------------------------------

/// Busy-poll until the drive clears the BSY bit.
///
/// Returns IoError if the timeout expires before the device becomes ready.
fn wait_bsy() DeviceError!void {
    var timeout: u32 = 10_000_000;

    while ((port.inb(ATA_STATUS) & STATUS_BSY) != 0) {
        timeout -= 1;
        if (timeout == 0) return DeviceError.IoError;
    }
}

/// Busy-poll until the drive asserts the DRQ bit.
///
/// Returns IoError if the timeout expires before data becomes available.
fn wait_drq() DeviceError!void {
    var timeout: u32 = 10_000_000;

    while ((port.inb(ATA_STATUS) & STATUS_DRQ) == 0) {
        timeout -= 1;
        if (timeout == 0) return DeviceError.IoError;
    }
}

/// Issue four status-register reads to provide the ATA-specified
/// ~100 ns delay required after certain register writes.
fn io_delay() void {
    var i: u8 = 0;
    while (i < 4) : (i += 1) _ = port.inb(ATA_STATUS);
}
