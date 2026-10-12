// src/kernel/port_io.zig
//
// Low-level x86 port I/O primitives.
//
// These helpers provide direct access to the processor's I/O port
// space using the IN and OUT instructions. They are used by hardware
// drivers and platform-support code to communicate with legacy
// devices such as the PIC, PIT, keyboard controller, and ATA devices.
//
// All functions are synchronous, perform no allocation, and operate
// directly on hardware state.
//

/// Write an 8-bit value to an I/O port.
pub fn outb(port: u16, value: u8) void {
    asm volatile (
        "outb %[value], %[port]"
        :
        : [value] "{al}" (value),
                  [port]  "{dx}" (port),
    );
}

/// Read an 8-bit value from an I/O port.
pub fn inb(port: u16) u8 {
    return asm volatile (
        "inb %[port], %[ret]"
        : [ret] "={al}" (-> u8)
        : [port] "{dx}" (port),
    );
}

/// Write a 16-bit value to an I/O port.
pub fn outw(port: u16, value: u16) void {
    asm volatile (
        "outw %[value], %[port]"
        :
        : [value] "{ax}" (value),
                  [port]  "{dx}" (port),
    );
}

/// Read a 16-bit value from an I/O port.
pub fn inw(port: u16) u16 {
    return asm volatile (
        "inw %[port], %[ret]"
        : [ret] "={ax}" (-> u16)
        : [port] "{dx}" (port),
    );
}

/// Halt the processor indefinitely.
///
/// Intended for fatal error paths and low-level debugging scenarios
/// where execution cannot safely continue.
pub fn pause() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}
