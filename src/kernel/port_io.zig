// src/kernel/port_io.zig

pub fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
    :
    : [value] "{al}" (value),
                  [port] "{dx}" (port),
    );
}

pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
    : [ret] "={al}" (-> u8),
                         : [port] "{dx}" (port),
    );
}

pub fn outw(port: u16, value: u16) void {
    asm volatile ("outw %[value], %[port]"
    :
    : [value] "{ax}" (value),
                  [port] "{dx}" (port),
    );
}
