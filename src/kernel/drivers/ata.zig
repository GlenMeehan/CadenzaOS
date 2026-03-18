const std = @import("std");
const port = @import("../port_io.zig");
const BlockDevice = @import("../fs/block_device.zig").BlockDevice;
const vga = @import("../vga.zig");

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

pub const MyOSHeader = extern struct {
    magic: u32,
    version: u16,
    label_a: u64,
    label_b: u16,
    block_count: u32,
    root_dir_lba: u32,
    // Use a padding array in an 'extern' struct—this is allowed!
    padding: [488]u8,
};

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
        const header = @as(*const MyOSHeader, @ptrCast(@alignCast(&buffer)));
        return header.magic == 0xDEAFBEEF;
    }

    pub fn readBlocks(ctx: ?*anyopaque, lba: u64, buf: []u8) DeviceError!void {
        _ = ctx;
        const sectors = @as(u8, @intCast(buf.len / 512));

        port.outb(ATA_DRIVE_SELECT, 0xE0 | @as(u8, @intCast((lba >> 24) & 0x0F)));
        io_delay();

        port.outb(ATA_SECTOR_COUNT, sectors);
        port.outb(ATA_LBA_LOW, @as(u8, @intCast(lba & 0xFF)));
        port.outb(ATA_LBA_MID, @as(u8, @intCast((lba >> 8) & 0xFF)));
        port.outb(ATA_LBA_HIGH, @as(u8, @intCast((lba >> 16) & 0xFF)));
        port.outb(ATA_COMMAND, CMD_READ_PIO);

        var i: usize = 0;
        while (i < sectors) : (i += 1) {
            wait_bsy();
            wait_drq();
            var j: usize = 0;
            while (j < 256) : (j += 1) {
                const data = port.inw(ATA_DATA);
                const offset = (i * 512) + (j * 2);
                buf[offset] = @as(u8, @intCast(data & 0xFF));
                buf[offset + 1] = @as(u8, @intCast(data >> 8));
            }
        }
    }

    pub fn writeBlocks(ctx: ?*anyopaque, lba: u64, buf: []const u8) DeviceError!void {
        _ = ctx;
        const sectors = @as(u8, @intCast(buf.len / 512));

        port.outb(ATA_DRIVE_SELECT, 0xE0 | @as(u8, @intCast((lba >> 24) & 0x0F)));
        io_delay();

        port.outb(ATA_SECTOR_COUNT, sectors);
        port.outb(ATA_LBA_LOW, @as(u8, @intCast(lba & 0xFF)));
        port.outb(ATA_LBA_MID, @as(u8, @intCast((lba >> 8) & 0xFF)));
        port.outb(ATA_LBA_HIGH, @as(u8, @intCast((lba >> 16) & 0xFF)));
        port.outb(ATA_COMMAND, CMD_WRITE_PIO);

        var i: usize = 0;
        while (i < sectors) : (i += 1) {
            wait_bsy();
            wait_drq();
            var j: usize = 0;
            while (j < 256) : (j += 1) {
                const data = @as(u16, buf[(i * 512) + (j * 2)]) | (@as(u16, buf[(i * 512) + (j * 2) + 1]) << 8);
                port.outw(ATA_DATA, data);
            }
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
    const header = @as(*MyOSHeader, @ptrCast(@alignCast(&buffer)));
    header.magic = 0xDEAFBEEF;
    header.version = 1;
    header.block_count = 20480;

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
