// src/kernel/pic.zig

const io = @import("port_io.zig");

const MASTER_CMD: u16 = 0x20;
const MASTER_DATA: u16 = 0x21;
const SLAVE_CMD: u16 = 0xA0;
const SLAVE_DATA: u16 = 0xA1;

pub fn remap(master_offset: u8, slave_offset: u8) void {
    // Save current masks
    const master_mask = io.inb(MASTER_DATA);
    const slave_mask = io.inb(SLAVE_DATA);

    // Start initialization (ICW1)
    io.outb(MASTER_CMD, 0x11);
    io.outb(SLAVE_CMD, 0x11);

    // Set vector offsets (ICW2)
    io.outb(MASTER_DATA, master_offset);
    io.outb(SLAVE_DATA, slave_offset);

    // Wiring (ICW3)
    io.outb(MASTER_DATA, 0x04); // slave on IRQ2
    io.outb(SLAVE_DATA, 0x02);  // cascade identity

    // Environment info (ICW4)
    io.outb(MASTER_DATA, 0x01);
    io.outb(SLAVE_DATA, 0x01);

    // Restore masks
    io.outb(MASTER_DATA, master_mask);
    io.outb(SLAVE_DATA, slave_mask);
}

pub fn unmaskIrq(irq: u8) void {
    if (irq < 8) {
        const mask = io.inb(MASTER_DATA);
        const bit: u3 = @intCast(irq); // irq is 0–7 here
        io.outb(MASTER_DATA, mask & ~(@as(u8, 1) << bit));
    } else {
        const mask = io.inb(SLAVE_DATA);
        const bit: u3 = @intCast(irq - 8); // also 0–7
        io.outb(SLAVE_DATA, mask & ~(@as(u8, 1) << bit));
    }
}
