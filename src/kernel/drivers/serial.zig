// src/kernel/drivers/serial.zig
//
// UART serial driver for COM1 (I/O base 0x3F8).
// Provides synchronous, polled output and input.
// Output is visible in QEMU via -serial stdio, or on real hardware
// via a USB-to-serial adapter connected to another machine.

const port = @import("../port_io.zig");

// COM1 register ports
const COM1_BASE: u16 = 0x3F8;
const DATA: u16 = COM1_BASE + 0; // Data register (read/write)
const IER:  u16 = COM1_BASE + 1; // Interrupt Enable Register
const FCR:  u16 = COM1_BASE + 2; // FIFO Control Register
const LCR:  u16 = COM1_BASE + 3; // Line Control Register
const MCR:  u16 = COM1_BASE + 4; // Modem Control Register
const LSR:  u16 = COM1_BASE + 5; // Line Status Register

// Line Status Register bits
const LSR_DR:   u8 = 0x01; // Data Ready — received byte available
const LSR_THRE: u8 = 0x20; // Transmit Holding Register Empty — ready to send

/// Initialise COM1 at 38400 baud, 8N1.
/// Must be called once during kmain before any write calls.
pub fn init() void {
    port.outb(IER,  0x00); // Disable all interrupts
    port.outb(LCR,  0x80); // Enable DLAB to set baud rate divisor
    port.outb(DATA, 0x03); // Divisor low byte: 3 = 38400 baud
    port.outb(IER,  0x00); // Divisor high byte: 0
    port.outb(LCR,  0x03); // 8 bits, no parity, one stop bit; clears DLAB
    port.outb(FCR,  0xC7); // Enable FIFO, clear, 14-byte threshold
    port.outb(MCR,  0x03); // RTS and DTR active
}

/// Busy-poll until the transmit holding register is empty,
/// then send one byte.
pub fn putChar(c: u8) void {
    while ((port.inb(LSR) & LSR_THRE) == 0) {}
    port.outb(DATA, c);
}

/// Write a string to the serial port.
/// Newlines are expanded to CR+LF for terminal compatibility.
pub fn writeString(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') putChar('\r');
        putChar(c);
    }
}

/// Read one byte from the serial port if available.
/// Returns null if no data is ready.
pub fn readByte() ?u8 {
    if ((port.inb(LSR) & LSR_DR) == 0) return null;
    return port.inb(DATA);
}
