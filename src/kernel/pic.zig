// src/kernel/pic.zig
//
// 8259A Programmable Interrupt Controller (PIC) control.
// Provides:
//   • remap()     — move IRQ vectors to new IDT offsets
//   • unmaskIrq() — enable a specific IRQ line
//
// This is required before enabling hardware interrupts so that
// IRQ0–IRQ15 do not overlap CPU exception vectors (0–31).

const io = @import("port_io.zig");

// PIC I/O ports
const MASTER_CMD:  u16 = 0x20;
const MASTER_DATA: u16 = 0x21;
const SLAVE_CMD:   u16 = 0xA0;
const SLAVE_DATA:  u16 = 0xA1;

/// Remap the PIC interrupt vectors.
/// `master_offset` — new IDT vector for IRQ0
/// `slave_offset`  — new IDT vector for IRQ8
///
/// Standard OSDev mapping is:
///     master_offset = 0x20
///     slave_offset  = 0x28
pub fn remap(master_offset: u8, slave_offset: u8) void {
    // Save current interrupt masks
    const master_mask = io.inb(MASTER_DATA);
    const slave_mask  = io.inb(SLAVE_DATA);

    // --- ICW1: Start initialization ---
    io.outb(MASTER_CMD, 0x11);
    io.outb(SLAVE_CMD,  0x11);

    // --- ICW2: Set vector offsets ---
    io.outb(MASTER_DATA, master_offset);
    io.outb(SLAVE_DATA,  slave_offset);

    // --- ICW3: Wiring information ---
    io.outb(MASTER_DATA, 0x04); // Slave PIC is on IRQ2
    io.outb(SLAVE_DATA,  0x02); // Slave identity (cascade)

    // --- ICW4: Environment info ---
    io.outb(MASTER_DATA, 0x01); // 8086/88 mode
    io.outb(SLAVE_DATA,  0x01);

    // Restore saved masks
    io.outb(MASTER_DATA, master_mask);
    io.outb(SLAVE_DATA,  slave_mask);
}

/// Unmask (enable) a specific IRQ line.
/// IRQ 0–7  → master PIC
/// IRQ 8–15 → slave PIC
pub fn unmaskIrq(irq: u8) void {
    if (irq < 8) {
        const mask = io.inb(MASTER_DATA);
        const bit: u3 = @intCast(irq);
        io.outb(MASTER_DATA, mask & ~(@as(u8, 1) << bit));
    } else {
        const mask = io.inb(SLAVE_DATA);
        const bit: u3 = @intCast(irq - 8);
        io.outb(SLAVE_DATA, mask & ~(@as(u8, 1) << bit));
    }
}
