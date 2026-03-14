//src/kernel/drivers/ata.zig

const std = @import("std");
const port = @import("../port_io.zig");
const BlockDevice = @import("../fs/block_device.zig").BlockDevice;

const DeviceError = error{IoError, OutOfRange};

const ATA_DATA        = 0x1F0;
const ATA_SECTOR_COUNT = 0x1F2;
const ATA_LBA_LOW      = 0x1F3;
const ATA_LBA_MID      = 0x1F4;
const ATA_LBA_HIGH     = 0x1F5;
const ATA_DRIVE_SELECT = 0x1F6;
const ATA_COMMAND      = 0x1F7;
const ATA_STATUS       = 0x1F7;

const CMD_READ_PIO  = 0x20;
const CMD_WRITE_PIO = 0x30;

const STATUS_BSY = 0x80;
const STATUS_DRQ = 0x08;
const STATUS_ERR = 0x01;

fn wait_bsy() void {
    var timer: u32 = 0;
    while (true) {
        const status = port.inb(ATA_STATUS);
        if (status == 0xFF) @panic("ATA: No drive (0xFF)");
        if ((status & STATUS_ERR) != 0) @panic("ATA: Hardware Error");
        if ((status & STATUS_BSY) == 0) break;

        timer += 1;
        if (timer > 1000000) {
            // If we hit this, the BSY bit is stuck ON
            @panic("ATA: Stuck Busy (BSY never cleared)");
        }
    }
}

fn wait_drq() void {
    while (true) {
        const status = port.inb(ATA_STATUS);
        if (status == 0xFF) @panic("ATA: No drive detected (0xFF)");
        if ((status & STATUS_ERR) != 0) @panic("ATA: Hardware Error during DRQ wait");
        if ((status & STATUS_DRQ) != 0) break;
    }
}

fn io_delay() void {
    comptime var i: u8 = 0;
    inline while (i < 5) : (i += 1) {
        _ = port.inb(ATA_STATUS);
    }
}

pub const AtaDevice = struct {
    pub fn asBlockDevice(self: *AtaDevice) BlockDevice {
        return BlockDevice{
            .ctx = self,
            .block_size = 512,
            .total_blocks = 20480, // Matches your build.sh (10MB)
            .readBlocks = readBlocks,
            .writeBlocks = writeBlocks,
        };
    }


    // Then update your readBlocks like this:
    fn readBlocks(ctx: *anyopaque, lba: u64, buf: []u8) DeviceError!void {
        _ = ctx;
        if (lba + (buf.len / 512) > 20480) return error.OutOfRange;
        const sectors = @as(u8, @intCast(buf.len / 512));

        // 1. Select the drive (Master)
        // 0xE0 is for Master, 0xF0 is for Slave.
        // We use LBA mode (bit 6 = 1)
        port.outb(ATA_DRIVE_SELECT, 0xE0 | @as(u8, @intCast((lba >> 24) & 0x0F)));
        io_delay();

        // 2. Some controllers need the sector count to be 0 before setting LBA
        port.outb(ATA_SECTOR_COUNT, 0);

        // 3. Wait for the drive to be ready for a command
        wait_bsy();

        // 4. Send parameters
        port.outb(ATA_SECTOR_COUNT, sectors);
        port.outb(ATA_LBA_LOW,  @as(u8, @intCast(lba & 0xFF)));
        port.outb(ATA_LBA_MID,  @as(u8, @intCast((lba >> 8) & 0xFF)));
        port.outb(ATA_LBA_HIGH, @as(u8, @intCast((lba >> 16) & 0xFF)));

        // 5. Issue the Read command
        port.outb(ATA_COMMAND,  CMD_READ_PIO);
        io_delay();

        var i: usize = 0;
        while (i < sectors) : (i += 1) {
            // We must wait for BSY to clear AND DRQ to set
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

    fn writeBlocks(ctx: *anyopaque, lba: u64, buf: []const u8) DeviceError!void {
        _ = ctx;
        if (lba + (buf.len / 512) > 20480) return error.OutOfRange;
        const sectors = @as(u8, @intCast(buf.len / 512));

        wait_bsy();
        port.outb(ATA_DRIVE_SELECT, 0xE0 | @as(u8, @intCast((lba >> 24) & 0x0F)));
        port.outb(ATA_SECTOR_COUNT, sectors);
        port.outb(ATA_LBA_LOW,  @as(u8, @intCast(lba & 0xFF)));
        port.outb(ATA_LBA_MID,  @as(u8, @intCast((lba >> 8) & 0xFF)));
        port.outb(ATA_LBA_HIGH, @as(u8, @intCast((lba >> 16) & 0xFF)));
        port.outb(ATA_COMMAND,  CMD_WRITE_PIO);

        var i: usize = 0;
        while (i < sectors) : (i += 1) {
            wait_bsy();
            wait_drq();

            var j: usize = 0;
            while (j < 256) : (j += 1) {
                const offset = (i * 512) + (j * 2);
                const data = @as(u16, buf[offset]) | (@as(u16, buf[offset + 1]) << 8);
                port.outw(ATA_DATA, data);
            }
        }
    }
};
