// src/kernel/apic.zig

const std = @import("std");
const mem_mod = @import("memory.zig"); // <--- ADD THIS IMPORT

// Default physical locations specified by the x86 architecture
pub const LAPIC_PHYS_BASE: u64 = 0xFEE00000;
pub const IOAPIC_PHYS_BASE: u64 = 0xFEC00000;

// Map at fixed safe virtual addresses below the overflow boundary
pub const LAPIC_VIRT_BASE: u64  = 0xFFFFFF8100000000;  // beyond 1GB huge page coverage
pub const IOAPIC_VIRT_BASE: u64 = 0xFFFFFF8100001000;  // next 4KB page

// -----------------------------------------------------------------------------
//  LAPIC REGISTER PRIMITIVES
// -----------------------------------------------------------------------------

/// Read a 32-bit register from the Local APIC
pub inline fn lapicRead(offset: u32) u32 {
    const ptr = @as(*volatile u32, @ptrFromInt(LAPIC_VIRT_BASE + offset));
    return ptr.*;
}

/// Write a 32-bit register to the Local APIC
pub inline fn lapicWrite(offset: u32, value: u32) void {
    var base: u64 = LAPIC_VIRT_BASE;
    asm volatile ("" : [b] "+r" (base)); // Prevents compiler constant-folding

    const ptr = @as(*volatile u32, @ptrFromInt(base + @as(u64, offset)));
    ptr.* = value;
}

// -----------------------------------------------------------------------------
//  I/O APIC INDIRECT REGISTER PRIMITIVES
// -----------------------------------------------------------------------------

const IOREGSEL = 0x00;
const IOWIN    = 0x10;

/// Read a 32-bit register indirectly from the I/O APIC
pub fn ioApicRead(reg_index: u32) u32 {
    const regsel = @as(*volatile u32, @ptrFromInt(IOAPIC_VIRT_BASE + IOREGSEL));
    const iowin  = @as(*volatile u32, @ptrFromInt(IOAPIC_VIRT_BASE + IOWIN));

    regsel.* = reg_index;
    return iowin.*;
}

/// Write a 32-bit register indirectly to the I/O APIC
pub fn ioApicWrite(reg_index: u32, value: u32) void {
    var base: u64 = IOAPIC_VIRT_BASE;
    asm volatile ("" : [b] "+r" (base)); // Forces address into a register

    const regsel = @as(*volatile u32, @ptrFromInt(base + IOREGSEL));
    const iowin  = @as(*volatile u32, @ptrFromInt(base + IOWIN));

    regsel.* = reg_index;
    iowin.* = value;
}

/// Safely probes the LAPIC hardware to read the primary core's APIC ID.
pub fn probeApicId() u32 {
    const LAPIC_ID_REG = 0x20;
    return (lapicRead(LAPIC_ID_REG) >> 24) & 0xFF;
}

/// Probes the I/O APIC indirectly to discover how many hardware interrupt lines
/// it is capable of routing.
pub fn probeMaxIrqs() u32 {
    const version_reg = ioApicRead(0x01);
    return (version_reg >> 16) & 0xFF;
}

pub fn debugRawLapic() u32 {
    return lapicRead(0x30);
}

pub fn debugRawIoApic() u32 {
    // Read Register 0x01 (IOAPIC Version & Max Redirection Entries)
    return ioApicRead(0x01);
}

// -----------------------------------------------------------------------------
//  LAPIC TIMER & CONTROL REGISTERS
// -----------------------------------------------------------------------------

const LAPIC_SVR: u32        = 0x0F0; // Spurious Vector Register
const LAPIC_EOI: u32        = 0x0B0; // End Of Interrupt Register
const LAPIC_LVT_TIMER: u32  = 0x320; // Local Vector Table Timer Register
const LAPIC_TIMER_INIT: u32 = 0x380; // Initial Count Register
const LAPIC_TIMER_DIV: u32  = 0x3E0; // Divide Configuration Register

/// Software-enable the Local APIC
pub fn enableApicSoftware() void {
    // Bit 8 (0x100) = Enable APIC; Bits 0-7 (0xFF) = Spurious Vector
    lapicWrite(LAPIC_SVR, lapicRead(LAPIC_SVR) | 0x1FF);
}

/// Send End-Of-Interrupt to the Local APIC
pub fn sendEoi() void {
    lapicWrite(LAPIC_EOI, 0);
}

/// Configure and start the Local APIC Periodic Timer
pub fn initLapicTimer(vector: u8) void {
    // 1. Divide Configuration = 16 (0x03)
    lapicWrite(LAPIC_TIMER_DIV, 0x03);

    // 2. Configure LVT Timer: Vector | Periodic Mode (Bit 17 / 0x20000)
    lapicWrite(LAPIC_LVT_TIMER, @as(u32, vector) | 0x20000);

    // 3. Set Initial Count to start ticking
    lapicWrite(LAPIC_TIMER_INIT, 0x00080000);
}

/// Route ISA IRQ1 (Keyboard) to IDT Vector 33 (0x21) via I/O APIC
pub fn initIoApicKeyboard() void {
    // IRQ1 Redirection Entry starts at register index 0x12 (Low) and 0x13 (High)
    // Map IRQ1 -> Vector 33 (0x21), Fixed Delivery Mode, Unmasked
    ioApicWrite(0x12, 0x21); // Low 32 bits: Vector 33
    ioApicWrite(0x13, 0x00); // High 32 bits: Destination APIC ID 0
}

/// Route ISA IRQ12 (PS/2 Mouse) to IDT Vector 44 (0x2C) via I/O APIC
pub fn initIoApicMouse() void {
    // IRQ12 Redirection Entry index = 0x10 + (12 * 2) = 0x28 (Low) and 0x29 (High)
    // Map IRQ12 -> Vector 44 (0x2C), Fixed Delivery Mode, Unmasked
    ioApicWrite(0x28, 0x2C); // Low 32 bits: Vector 44 (0x2C)
    ioApicWrite(0x29, 0x00); // High 32 bits: Destination APIC ID 0
}
