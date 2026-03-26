// src/kernel/drivers/ata.zig

const std = @import("std");
const port = @import("../port_io.zig");
const BlockDevice = @import("../fs/block_device.zig").BlockDevice;
const vga = @import("../vga.zig");
const fs = @import("../fs/coda_fs.zig");


const DeviceError = error{ IoError, OutOfRange };

const ATA_DATA = 0x1F0;
const ATA_SECTOR_COUNT = 0x1F2;
const ATA_LBA_LOW = 0x1F3;
const ATA_LBA_MID = 0x1F4;
const ATA_LBA_HIGH = 0x1F5;
const ATA_DRIVE_SELECT = 0x1F6;
const ATA_COMMAND = 0x1F7;
const ATA_STATUS = 0x1F7;

const CMD_READ_PIO = 0x20;
const CMD_WRITE_PIO = 0x30;

const STATUS_BSY = 0x80;
const STATUS_DRQ = 0x08;
const STATUS_ERR = 0x01;

const Superblock = fs.Superblock;


pub const AtaDevice = struct {
    pub fn asBlockDevice(self: *AtaDevice) BlockDevice {
        return BlockDevice{
            .ctx = self,
            .block_size = 512,
            .total_blocks = 20480,
            .readBlocks = readBlocks,
            .writeBlocks = writeBlocks,
        };
    }

    pub fn checkFileSystem(lba: u32) bool {
        // 1. Force the buffer to 8-byte alignment to match the struct
        var buffer: [512]u8 align(8) = undefined;

        // Read the data
        readBlocks(null, lba, &buffer) catch return false;

        // 2. Use @alignCast to satisfy the compiler
        const header = @as(*Superblock, @ptrCast(@alignCast(&buffer)));
        return header.magic == 0xDEAFBEEF;
    }

    pub fn readBlocks(ctx: ?*anyopaque, lba: u64, buf: []u8) DeviceError!void {
        _ = ctx;
        var sectors_remaining = (buf.len + 511) / 512;
        var current_lba = lba;
        var current_offset: usize = 0;

        while (sectors_remaining > 0) {
            // Read in chunks of 128 sectors (64KB) to avoid u8 overflow
            const sectors_to_read = if (sectors_remaining > 128) @as(u8, 128) else @as(u8, @truncate(sectors_remaining));

            port.outb(ATA_DRIVE_SELECT, @as(u8, @truncate(0xE0 | ((current_lba >> 24) & 0x0F))));
            io_delay();

            port.outb(ATA_SECTOR_COUNT, sectors_to_read);
            port.outb(ATA_LBA_LOW, @as(u8, @truncate(current_lba & 0xFF)));
            port.outb(ATA_LBA_MID, @as(u8, @truncate((current_lba >> 8) & 0xFF)));
            port.outb(ATA_LBA_HIGH, @as(u8, @truncate((current_lba >> 16) & 0xFF)));
            port.outb(ATA_COMMAND, CMD_READ_PIO);

            var i: usize = 0;
            while (i < sectors_to_read) : (i += 1) {
                wait_bsy();
                wait_drq();
                var j: usize = 0;
                while (j < 256) : (j += 1) {
                    const data = port.inw(ATA_DATA);

                    if (current_offset < buf.len) {
                        buf[current_offset] = @as(u8, @truncate(data & 0xFF));
                    }
                    if (current_offset + 1 < buf.len) {
                        buf[current_offset + 1] = @as(u8, @truncate(data >> 8));
                    }
                    current_offset += 2;
                }
            }

            sectors_remaining -= sectors_to_read;
            current_lba += sectors_to_read;
        }
    }

    pub fn writeBlocks(ctx: ?*anyopaque, lba: u64, buf: []const u8) DeviceError!void {
        _ = ctx;
        const total_sectors = @as(u32, @intCast((buf.len + 511) / 512));
        if (total_sectors == 0) return;

        var current_sector: u32 = 0;
        port.outb(0x3F6, 0x02);
        while (current_sector < total_sectors) : (current_sector += 1) {
            wait_bsy();
            const current_lba = lba + current_sector;

            // 1. Select Drive & LBA
            port.outb(ATA_DRIVE_SELECT, 0x40 | @as(u8, @intCast((current_lba >> 24) & 0x0F)));
            io_delay();

            // 2. We write 1 sector at a time for maximum compatibility during mkfs
            port.outb(ATA_SECTOR_COUNT, 1);
            port.outb(ATA_LBA_LOW, @as(u8, @intCast(current_lba & 0xFF)));
            port.outb(ATA_LBA_MID, @as(u8, @intCast((current_lba >> 8) & 0xFF)));
            port.outb(ATA_LBA_HIGH, @as(u8, @intCast((current_lba >> 16) & 0xFF)));


            io_delay(); // Give the hardware a literal moment to react

            // 3. Command: WRITE
            port.outb(ATA_COMMAND, CMD_WRITE_PIO);
            io_delay();

            // 4. WAIT for the drive to be ready for data
            while (port.inb(ATA_STATUS) & (1 << 7) != 0) {}
            const status = port.inb(ATA_STATUS);
            if ((status & ((1 << 0) | (1 << 5))) != 0) return DeviceError.IoError;
            while ((port.inb(ATA_STATUS) & (1 << 3)) == 0) {}

            // 5. Transfer the 256 words (512 bytes)
            var j: usize = 0;
            while (j < 256) : (j += 1) {
                const offset = (current_sector * 512) + (j * 2);
                var data: u16 = 0;

                if (offset + 1 < buf.len) {
                    // Both bytes exist in the buffer
                    data = @as(u16, buf[offset]) | (@as(u16, buf[offset + 1]) << 8);
                } else if (offset < buf.len) {
                    // Only one byte remains (odd-sized buffer)
                    data = @as(u16, buf[offset]);
                } else {
                    // Buffer is exhausted, send 0s to fill the 512-byte hardware requirement
                    data = 0;
                }

                port.outw(ATA_DATA, data);
            }

            // 6. Final Status Check (Crucial for multi-sector flushes)
            _ = port.inb(ATA_STATUS);

            // 7. Flush Cache: Forces the drive to write its internal buffer to the physical disk
            port.outb(ATA_COMMAND, 0xE7);
            wait_bsy(); // Wait for the drive to confirm the flush is complete
        }
    }
};

// --- Top-Level Functions for Kernel Bring-up ---

pub fn initializePartitionTable(start_lba: u32, size_in_sectors: u32) void {
    // Explicitly tell Zig this is a [512]u8 array
    var buffer: [512]u8 align(8) = undefined;

    // 1. READ the existing MBR
    AtaDevice.readBlocks(null, 0, &buffer) catch {
        vga.writeString("Error: Could not read MBR\n", 12, 0);
        return;
    };

    // 2. Set the Partition 1 entry (at offset 446)
    // We leave bytes 0..445 untouched so the bootloader stays intact
    const offset = 446;
    buffer[offset + 0] = 0x80; // Bootable
    buffer[offset + 4] = 0x83; // Type: Linux/Generic

    // Set Start LBA and Size
    std.mem.writeInt(u32, buffer[offset + 8..offset + 12], start_lba, .little);
    std.mem.writeInt(u32, buffer[offset + 12..offset + 16], size_in_sectors, .little);

    // 3. Ensure the Boot Signature is present
    buffer[510] = 0x55;
    buffer[511] = 0xAA;

    // 4. WRITE it back to Sector 0
    AtaDevice.writeBlocks(null, 0, &buffer) catch {
        vga.writeString("Error: Could not write MBR\n", 12, 0);
    };
}

pub fn formatMyFileSystem(lba: u32) void {
    // 1. Align to 8
    var buffer align(8) = std.mem.zeroes([512]u8);

    // 2. Cast with @alignCast
    const header = @as(*Superblock, @ptrCast(@alignCast(&buffer)));

    header.magic = 0xDEAFBEEF;
    header.version = 1;
    header.block_size = 512;
    header.total_blocks = 20480; // or block_count, whichever matches coda_fs.zig
    header.flags = 0;

    AtaDevice.writeBlocks(null, @as(u64, lba), &buffer) catch {};
}

// --- Helpers ---

fn wait_bsy() void {
    while ((port.inb(ATA_STATUS) & STATUS_BSY) != 0) {}
}

fn wait_drq() void {
    while ((port.inb(ATA_STATUS) & STATUS_DRQ) == 0) {}
}

fn io_delay() void {
    var i: u8 = 0;
    while (i < 4) : (i += 1) _ = port.inb(ATA_STATUS);
}
