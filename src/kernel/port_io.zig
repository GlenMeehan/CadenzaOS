// src/kernel/port_io.zig
//
// Low‑level port I/O helpers for x86.
// These wrap the `in`/`out` instructions using inline assembly.
// All functions are `noreturn` or side‑effect‑only and never allocate.

/// Write an 8‑bit value to an I/O port.
pub fn outb(port: u16, value: u8) void {
    asm volatile (
        "outb %[value], %[port]"
        :
        : [value] "{al}" (value),
                  [port]  "{dx}" (port),
    );
}

/// Read an 8‑bit value from an I/O port.
pub fn inb(port: u16) u8 {
    return asm volatile (
        "inb %[port], %[ret]"
        : [ret] "={al}" (-> u8)
        : [port] "{dx}" (port),
    );
}

/// Write a 16‑bit value to an I/O port.
pub fn outw(port: u16, value: u16) void {
    asm volatile (
        "outw %[value], %[port]"
        :
        : [value] "{ax}" (value),
                  [port]  "{dx}" (port),
    );
}

/// Read a 16‑bit value from an I/O port.
pub fn inw(port: u16) u16 {
    return asm volatile (
        "inw %[port], %[ret]"
        : [ret] "={ax}" (-> u16)
        : [port] "{dx}" (port),
    );
}

/// Halt the CPU forever.
/// Useful as a final fallback when shutdown/reboot fails.
pub fn pause() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}
