// src/kernel/pic.zig
//
// 8259A Programmable Interrupt Controller (PIC) support.
//
// Provides:
//   • remap()     — relocate IRQ vectors within the IDT
//   • unmaskIrq() — enable delivery of a specific IRQ line
//
// PIC remapping is required before enabling hardware interrupts so
// that IRQ vectors do not overlap the processor exception range
// (vectors 0–31).
//
const io = @import("port_io.zig");

// -----------------------------------------------------------------------------
//  PIC I/O PORTS
// -----------------------------------------------------------------------------

/// Master PIC command port.
const MASTER_CMD: u16 = 0x20;

/// Master PIC data port.
const MASTER_DATA: u16 = 0x21;

/// Slave PIC command port.
const SLAVE_CMD: u16 = 0xA0;

/// Slave PIC data port.
const SLAVE_DATA: u16 = 0xA1;

/// Remap hardware IRQ vectors to new IDT offsets.
///
/// Parameters:
///   master_offset - Interrupt vector assigned to IRQ0
///   slave_offset  - Interrupt vector assigned to IRQ8
///
/// The conventional x86 operating-system layout is:
///
///     IRQ0-IRQ7   -> 0x20-0x27
///     IRQ8-IRQ15  -> 0x28-0x2F
///
/// This avoids conflicts with the CPU exception vectors located
/// at 0x00-0x1F.
pub fn remap(master_offset: u8, slave_offset: u8) void {

    // Preserve the current interrupt masks so they can be restored
    // after reconfiguration.
    const master_mask = io.inb(MASTER_DATA);
    const slave_mask  = io.inb(SLAVE_DATA);

    // -------------------------------------------------------------------------
    //  ICW1 - Enter initialisation mode
    // -------------------------------------------------------------------------

    io.outb(MASTER_CMD, 0x11);
    io.outb(SLAVE_CMD,  0x11);

    // -------------------------------------------------------------------------
    //  ICW2 - Configure vector offsets
    // -------------------------------------------------------------------------

    io.outb(MASTER_DATA, master_offset);
    io.outb(SLAVE_DATA,  slave_offset);

    // -------------------------------------------------------------------------
    //  ICW3 - Configure master/slave cascade wiring
    // -------------------------------------------------------------------------

    io.outb(MASTER_DATA, 0x04); // Slave PIC connected to IRQ2
    io.outb(SLAVE_DATA,  0x02); // Slave cascade identity

    // -------------------------------------------------------------------------
    //  ICW4 - Enable 8086/88 operating mode
    // -------------------------------------------------------------------------

    io.outb(MASTER_DATA, 0x01);
    io.outb(SLAVE_DATA,  0x01);

    // Restore the previously active interrupt masks.
    io.outb(MASTER_DATA, master_mask);
    io.outb(SLAVE_DATA,  slave_mask);
}

/// Unmask (enable) a hardware IRQ line.
///
/// IRQs 0-7 are managed by the master PIC.
/// IRQs 8-15 are managed by the slave PIC.
pub fn unmaskIrq(irq: u8) void {
    if (irq < 8) {
        const mask = io.inb(MASTER_DATA);
        const bit: u3 = @intCast(irq);

        io.outb(
            MASTER_DATA,
            mask & ~(@as(u8, 1) << bit),
        );
    } else {
        const mask = io.inb(SLAVE_DATA);
        const bit: u3 = @intCast(irq - 8);

        io.outb(
            SLAVE_DATA,
            mask & ~(@as(u8, 1) << bit),
        );
    }
}
