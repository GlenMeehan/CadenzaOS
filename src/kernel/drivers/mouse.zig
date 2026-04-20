// src/kernel/drivers/mouse.zig
//
// PS/2 Mouse Driver
// -----------------
// Initialises the PS/2 auxiliary port and puts the mouse into
// streaming mode so it generates IRQ12 on movement and button events.
//
// All communication goes through the 8042 PS/2 controller:
//   0x64 — command / status port
//   0x60 — data port
//
// No packet decoding is implemented here; that belongs in the IRQ12 handler.

const io = @import("../port_io.zig");

// ----------------------------------------------------------------
// Private helpers
// ----------------------------------------------------------------

/// Busy-poll until the controller's input buffer is empty (bit 1 clear).
/// Must be called before writing to port 0x64 or 0x60.
fn waitWrite() void {
    while ((io.inb(0x64) & 0b10) != 0) {}
}

/// Busy-poll until the controller's output buffer is full (bit 0 set).
/// Must be called before reading from port 0x60.
fn waitRead() void {
    while ((io.inb(0x64) & 0b1) == 0) {}
}

/// Send a byte to the mouse via the PS/2 controller.
/// Prefixes the write with the 0xD4 "route to auxiliary device" command.
fn mouseWrite(byte: u8) void {
    waitWrite();
    io.outb(0x64, 0xD4);  // Route next data byte to the auxiliary (mouse) port
    waitWrite();
    io.outb(0x60, byte);
}

/// Read one byte from the PS/2 data port.
fn mouseRead() u8 {
    waitRead();
    return io.inb(0x60);
}

// ----------------------------------------------------------------
// Public interface
// ----------------------------------------------------------------

/// Initialise the PS/2 mouse.
///
/// Steps:
///   1. Enable the auxiliary PS/2 port
///   2. Enable IRQ12 in the controller configuration byte
///   3. Reset the mouse to its default state
///   4. Enable streaming mode (mouse sends packets on movement / click)
pub fn initMouse() void {
    // 1. Enable the auxiliary PS/2 port
    waitWrite();
    io.outb(0x64, 0xA8);

    // 2. Enable IRQ12 in the controller configuration byte
    waitWrite();
    io.outb(0x64, 0x20);  // Request current command byte
    waitRead();
    const status = io.inb(0x60);

    waitWrite();
    io.outb(0x64, 0x60);          // Write command byte
    waitWrite();
    io.outb(0x60, status | 0b10); // Set bit 1 to enable IRQ12

    // 3. Reset mouse to defaults
    mouseWrite(0xF6);
    _ = mouseRead();  // ACK

    // 4. Enable streaming mode
    mouseWrite(0xF4);
    _ = mouseRead();  // ACK
}
