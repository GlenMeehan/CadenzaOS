// src/kernel/apic.zig

const std = @import("std");
const mem_mod = @import("memory.zig"); // Used by APIC mapping initialisation
const port   = @import("port_io.zig");
const serial = @import("drivers/serial.zig");
const conv   = @import("convert.zig");

// Architectural default physical addresses defined by x86.
//
// These are the standard locations used when APIC mode is enabled,
// although firmware may relocate them on some systems.
pub const LAPIC_PHYS_BASE: u64 = 0xFEE00000;
pub const IOAPIC_PHYS_BASE: u64 = 0xFEC00000;

// Fixed virtual addresses used by the kernel to access the APIC MMIO
// regions after paging has been established.
pub const LAPIC_VIRT_BASE: u64  = 0xFFFFFF8100000000;
pub const IOAPIC_VIRT_BASE: u64 = 0xFFFFFF8100001000;

// -----------------------------------------------------------------------------
//  LAPIC REGISTER PRIMITIVES
// -----------------------------------------------------------------------------

/// Read a 32-bit memory-mapped register from the Local APIC.
pub inline fn lapicRead(offset: u32) u32 {
    const ptr = @as(*volatile u32, @ptrFromInt(LAPIC_VIRT_BASE + offset));
    return ptr.*;
}

/// Write a 32-bit value to a Local APIC register.
///
/// The temporary register variable prevents the compiler from
/// aggressively constant-folding the MMIO address calculation.
pub inline fn lapicWrite(offset: u32, value: u32) void {
    var base: u64 = LAPIC_VIRT_BASE;
    asm volatile ("" : [b] "+r" (base));

    const ptr = @as(*volatile u32, @ptrFromInt(base + @as(u64, offset)));
    ptr.* = value;
}

// -----------------------------------------------------------------------------
//  I/O APIC INDIRECT REGISTER PRIMITIVES
// -----------------------------------------------------------------------------

// The I/O APIC exposes an indirect register interface.
// IOREGSEL selects a register and IOWIN accesses its value.
const IOREGSEL = 0x00;
const IOWIN    = 0x10;

/// Read a 32-bit I/O APIC register via the indirect register window.
pub fn ioApicRead(reg_index: u32) u32 {
    const regsel = @as(*volatile u32, @ptrFromInt(IOAPIC_VIRT_BASE + IOREGSEL));
    const iowin  = @as(*volatile u32, @ptrFromInt(IOAPIC_VIRT_BASE + IOWIN));

    regsel.* = reg_index;
    return iowin.*;
}

/// Write a 32-bit I/O APIC register via the indirect register window.
pub fn ioApicWrite(reg_index: u32, value: u32) void {
    var base: u64 = IOAPIC_VIRT_BASE;
    asm volatile ("" : [b] "+r" (base));

    const regsel = @as(*volatile u32, @ptrFromInt(base + IOREGSEL));
    const iowin  = @as(*volatile u32, @ptrFromInt(base + IOWIN));

    regsel.* = reg_index;
    iowin.* = value;
}

/// Read the Local APIC ID of the current processor.
///
/// The APIC ID occupies bits 24-31 of the Local APIC ID register.
pub fn probeApicId() u32 {
    const LAPIC_ID_REG = 0x20;
    return (lapicRead(LAPIC_ID_REG) >> 24) & 0xFF;
}

/// Query the I/O APIC version register and return the highest supported
/// redirection entry number.
///
/// The returned value is typically used to determine how many IRQ lines
/// the I/O APIC can route.
pub fn probeMaxIrqs() u32 {
    const version_reg = ioApicRead(0x01);
    return (version_reg >> 16) & 0xFF;
}

/// Development helper: read the Local APIC Version Register.
pub fn debugRawLapic() u32 {
    return lapicRead(0x30);
}

/// Development helper: read the I/O APIC Version Register.
pub fn debugRawIoApic() u32 {
    // I/O APIC Version Register
    return ioApicRead(0x01);
}

// -----------------------------------------------------------------------------
//  LAPIC TIMER & CONTROL REGISTERS
// -----------------------------------------------------------------------------

const LAPIC_SVR: u32        = 0x0F0; // Spurious Interrupt Vector Register
const LAPIC_EOI: u32        = 0x0B0; // End Of Interrupt Register
const LAPIC_LVT_TIMER: u32  = 0x320; // Local Vector Table Timer Entry
const LAPIC_TIMER_INIT: u32 = 0x380; // Initial Count Register
const LAPIC_TIMER_DIV: u32  = 0x3E0; // Divide Configuration Register

/// Enable the Local APIC in software.
///
/// Bit 8 enables APIC operation while bits 0-7 contain the spurious
/// interrupt vector.
pub fn enableApicSoftware() void {
    lapicWrite(LAPIC_SVR, lapicRead(LAPIC_SVR) | 0x1FF);
}

/// Signal End Of Interrupt (EOI) to the Local APIC.
///
/// Must be issued after servicing an interrupt delivered through
/// the APIC interrupt system.
pub fn sendEoi() void {
    lapicWrite(LAPIC_EOI, 0);
}

const LAPIC_TIMER_CUR: u32 = 0x390; // Current Count Register
const FALLBACK_COUNT: u32 = 0x00080000; // Old fixed value, used if measuring fails

/// Measure how many LAPIC timer ticks (divide-by-16) elapse in 10 ms,
/// using PIT channel 2 as the reference clock. That count is the
/// initial count for a 100 Hz periodic timer.
fn calibrateLapicTimer() u32 {
    const p61 = port.inb(0x61);

    // Gate off, speaker off, then program channel 2 for a 10 ms
    // one-shot (1193182 Hz / 100 = 11932 = 0x2E9C).
    port.outb(0x61, p61 & 0xFC);
    port.outb(0x43, 0xB0); // channel 2, lo/hi byte, mode 0, binary
    port.outb(0x42, 0x9C);
    port.outb(0x42, 0x2E);

    // LAPIC: divide 16, one-shot, masked (no interrupt), max count.
    lapicWrite(LAPIC_TIMER_DIV, 0x03);
    lapicWrite(LAPIC_LVT_TIMER, 0x10000 | 0x20);
    lapicWrite(LAPIC_TIMER_INIT, 0xFFFFFFFF);

    // Open the PIT gate to start its countdown.
    port.outb(0x61, (p61 & 0xFC) | 0x01);

    // Wait for PIT channel 2 output (port 0x61 bit 5) to go high.
    var done = false;
    var guard: u32 = 0;
    while (guard < 5_000_000) : (guard += 1) {
        if ((port.inb(0x61) & 0x20) != 0) {
            done = true;
            break;
        }
    }

    const cur = lapicRead(LAPIC_TIMER_CUR);
    lapicWrite(LAPIC_TIMER_INIT, 0); // stop the timer
    port.outb(0x61, p61);            // restore the original port state

    const elapsed: u32 = 0xFFFFFFFF - cur;

    var buf: [18]u8 = undefined;
    serial.writeString("LAPIC calib: count=");
    serial.writeString(conv.toHex(u64, elapsed, &buf));
    serial.writeString(if (done) "\n" else " (timeout, using fallback)\n");

    if (!done or elapsed < 1000) return FALLBACK_COUNT;
    return elapsed;
}

/// Configure and start the Local APIC timer in periodic mode.
///
/// The caller supplies the interrupt vector that will be generated
/// when the timer fires.
pub fn initLapicTimer(vector: u8) void {
    const count = calibrateLapicTimer();

    // 1. Configure timer divisor = 16.
    lapicWrite(LAPIC_TIMER_DIV, 0x03);

    // 2. Set periodic mode and interrupt vector.
    lapicWrite(LAPIC_LVT_TIMER, @as(u32, vector) | 0x20000);

    // 3. Load the initial countdown value.
        lapicWrite(LAPIC_TIMER_INIT, count);
}

/// Configure the I/O APIC to route ISA IRQ1 (keyboard)
/// to IDT vector 33 (0x21).
pub fn initIoApicKeyboard() void {

    // IRQ1 uses redirection entry 1:
    //   Low  register = 0x10 + (1 * 2) = 0x12
    //   High register = 0x13
    ioApicWrite(0x12, 0x21);
    ioApicWrite(0x13, 0x00);
}

/// Configure the I/O APIC to route ISA IRQ12 (PS/2 mouse)
/// to IDT vector 44 (0x2C).
pub fn initIoApicMouse() void {

    // IRQ12 uses redirection entry 12:
    //   Low  register = 0x10 + (12 * 2) = 0x28
    //   High register = 0x29
    ioApicWrite(0x28, 0x2C);
    ioApicWrite(0x29, 0x00);
}
