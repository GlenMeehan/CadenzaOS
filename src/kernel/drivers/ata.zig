// src/kernel/drivers/ata.zig
//
// ATA PIO Driver
// --------------
// Bare-metal ATA (IDE) driver using Programmed I/O (PIO) mode.
// Provides synchronous, sector-aligned read and write operations
// against the primary ATA bus (I/O base 0x1F0).
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
const CMD_FLUSH     = 0xE7;  // Flush write cache to disk

// --------------------------------
// Status register bit masks
// --------------------------------

const STATUS_BSY = 0x80;  // Drive busy
const STATUS_DRQ = 0x08;  // Data request — drive ready for transfer
const STATUS_ERR = 0x01;  // Error flag

// --------------------------------
// Error set
// --------------------------------

const DeviceError = error{ IoError, OutOfRange };

// --------------------------------
// AtaDevice
// --------------------------------

pub const AtaDevice = struct {

    /// Return a BlockDevice interface backed by this AtaDevice.
    /// Hard-codes 512-byte sectors and a 20480-sector (10 MiB) disk.
    /// Adjust total_blocks to match your actual disk geometry.
    pub fn asBlockDevice(self: *AtaDevice) BlockDevice {
        return BlockDevice{
            .ctx          = self,
            .block_size   = 512,
            .total_blocks = 20480,
            .readBlocks   = readBlocks,
            .writeBlocks  = writeBlocks,
        };
    }

    /// Probe whether a CODA filesystem exists at `lba`.
    ///
    /// WARNING: This function checks for the legacy magic value 0xDEAFBEEF,
    /// not the current CODA_MAGIC (0x434F44415F465331).
    /// It predates the current superblock format and should be updated or
    /// removed before use in production.
    pub fn checkFileSystem(lba: u32) bool {
        var buffer: [512]u8 align(8) = undefined;
        readBlocks(null, lba, &buffer) catch return false;
        const header = @as(*[512]u8, @ptrCast(@alignCast(&buffer)));
        // TODO: replace 0xDEAFBEEF with CODA_MAGIC and use the real Superblock type
        const magic = std.mem.readInt(u64, header[0..8], .little);
        return magic == 0xDEAFBEEF;
    }

    // ----------------------------------------------------------------
    // BlockDevice callbacks
    // ----------------------------------------------------------------

    /// Read one or more sectors beginning at `lba` into `buf`.
    /// `buf.len` determines how many bytes (and therefore sectors) are read.
    /// Reads in chunks of up to 128 sectors to avoid sector-count overflow.
    pub fn readBlocks(ctx: ?*anyopaque, lba: u64, buf: []u8) DeviceError!void {
        _ = ctx;

        var sectors_remaining = (buf.len + 511) / 512;
        var current_lba       = lba;
        var current_offset: usize = 0;

        while (sectors_remaining > 0) {
            const sectors_to_read: u8 = if (sectors_remaining > 128)
            128
            else
                @as(u8, @truncate(sectors_remaining));

            // Select drive (primary master, LBA mode) and upper LBA bits
            port.outb(ATA_DRIVE_SELECT, @as(u8, @truncate(0xE0 | ((current_lba >> 24) & 0x0F))));
            io_delay();

            port.outb(ATA_SECTOR_COUNT, sectors_to_read);
            port.outb(ATA_LBA_LOW,  @as(u8, @truncate( current_lba        & 0xFF)));
            port.outb(ATA_LBA_MID,  @as(u8, @truncate((current_lba >>  8) & 0xFF)));
            port.outb(ATA_LBA_HIGH, @as(u8, @truncate((current_lba >> 16) & 0xFF)));
            port.outb(ATA_COMMAND, CMD_READ_PIO);

            var i: usize = 0;
            while (i < sectors_to_read) : (i += 1) {
                wait_bsy();
                wait_drq();

                // Read 256 words (512 bytes) per sector
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
    /// Writes exactly one sector at a time for maximum hardware compatibility.
    /// Issues a cache-flush command (0xE7) after each sector.
    pub fn writeBlocks(ctx: ?*anyopaque, lba: u64, buf: []const u8) DeviceError!void {
        _ = ctx;

        const total_sectors = @as(u32, @intCast((buf.len + 511) / 512));
        if (total_sectors == 0) return;

        // Disable interrupts on the control register before starting a write sequence
        port.outb(0x3F6, 0x02);

        var current_sector: u32 = 0;
        while (current_sector < total_sectors) : (current_sector += 1) {
            wait_bsy();

            const current_lba = lba + current_sector;

            // 1. Select drive (primary master, LBA mode) and upper LBA bits
            port.outb(ATA_DRIVE_SELECT, 0x40 | @as(u8, @intCast((current_lba >> 24) & 0x0F)));
            io_delay();

            // 2. Write exactly one sector per iteration
            port.outb(ATA_SECTOR_COUNT, 1);
            port.outb(ATA_LBA_LOW,  @as(u8, @intCast( current_lba        & 0xFF)));
            port.outb(ATA_LBA_MID,  @as(u8, @intCast((current_lba >>  8) & 0xFF)));
            port.outb(ATA_LBA_HIGH, @as(u8, @intCast((current_lba >> 16) & 0xFF)));
            io_delay();

            // 3. Issue the write command
            port.outb(ATA_COMMAND, CMD_WRITE_PIO);
            io_delay();

            // 4. Wait for the drive to signal it is ready to accept data
            while (port.inb(ATA_STATUS) & STATUS_BSY != 0) {}
            const status = port.inb(ATA_STATUS);
            if ((status & (STATUS_ERR | (1 << 5))) != 0) return DeviceError.IoError;
            while ((port.inb(ATA_STATUS) & STATUS_DRQ) == 0) {}

            // 5. Transfer 256 words (512 bytes); pad with zeros if buf is exhausted
            var j: usize = 0;
            while (j < 256) : (j += 1) {
                const offset = (current_sector * 512) + (j * 2);
                const data: u16 = if (offset + 1 < buf.len)
                @as(u16, buf[offset]) | (@as(u16, buf[offset + 1]) << 8)
                else if (offset < buf.len)
                    @as(u16, buf[offset])
                    else
                        0;
                port.outw(ATA_DATA, data);
            }

            // 6. Read the alternate status register once (required by the ATA spec
            //    to let the drive update its status after the final word is written)
            _ = port.inb(ATA_STATUS);

            // 7. Flush the drive's write cache to guarantee persistence
            port.outb(ATA_COMMAND, CMD_FLUSH);
            wait_bsy();
        }
    }
};

// ----------------------------------------------------------------
// Top-level kernel helpers
// ----------------------------------------------------------------

/// Write a minimal partition table entry for partition 1 into the MBR.
/// Reads the existing MBR first so the bootloader code is preserved.
///
/// `start_lba`       — first sector of the partition
/// `size_in_sectors` — total sector count of the partition
pub fn initializePartitionTable(start_lba: u32, size_in_sectors: u32) void {
    var buffer: [512]u8 align(8) = undefined;

    AtaDevice.readBlocks(null, 0, &buffer) catch {
        vga.writeString("Error: Could not read MBR\n", 12, 0);
        return;
    };

    // Partition entry 1 starts at MBR offset 446
    const offset = 446;
    buffer[offset + 0] = 0x80;  // Bootable flag
    buffer[offset + 4] = 0x83;  // Partition type: Linux / generic

    std.mem.writeInt(u32, buffer[offset +  8..offset + 12], start_lba,       .little);
    std.mem.writeInt(u32, buffer[offset + 12..offset + 16], size_in_sectors, .little);

    // MBR boot signature
    buffer[510] = 0x55;
    buffer[511] = 0xAA;

    AtaDevice.writeBlocks(null, 0, &buffer) catch {
        vga.writeString("Error: Could not write MBR\n", 12, 0);
    };
}

/// Write a minimal legacy superblock to `lba`.
///
/// WARNING: Uses the legacy magic value 0xDEAFBEEF and does not initialise
/// the SpaceManager region or root directory extent.
/// This predates CodaFs.mkfs() and should not be used for new filesystems.
/// Retained here for reference only.
pub fn formatMyFileSystem(lba: u32) void {
    var buffer align(8) = std.mem.zeroes([512]u8);

    // TODO: replace with CodaFs.mkfs() — this does not produce a valid CODA filesystem
    std.mem.writeInt(u64, buffer[0..8],   0xDEAFBEEF, .little);  // legacy magic
    std.mem.writeInt(u32, buffer[8..12],  1,           .little);  // version
    std.mem.writeInt(u32, buffer[12..16], 512,         .little);  // block_size
    std.mem.writeInt(u64, buffer[16..24], 20480,       .little);  // total_blocks

    AtaDevice.writeBlocks(null, @as(u64, lba), &buffer) catch {};
}

// ----------------------------------------------------------------
// Private helpers
// ----------------------------------------------------------------

/// Busy-poll until the drive clears the BSY bit.
fn wait_bsy() void {
    while ((port.inb(ATA_STATUS) & STATUS_BSY) != 0) {}
}

/// Busy-poll until the drive sets the DRQ bit (ready for data transfer).
fn wait_drq() void {
    while ((port.inb(ATA_STATUS) & STATUS_DRQ) == 0) {}
}

/// Issue four dummy status reads to give the drive ~100 ns to update its state.
/// Required by the ATA specification after certain register writes.
fn io_delay() void {
    var i: u8 = 0;
    while (i < 4) : (i += 1) _ = port.inb(ATA_STATUS);
}
