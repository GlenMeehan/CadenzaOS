// src/kernel/port_io.zig

pub fn outb(port: u16, value: u8) void {
    asm volatile ("outb %al, %dx"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}

pub fn inb(port: u16) u8 {
    var result: u8 = 0;
    asm volatile ("inb %dx, %al"
        : [result] "={al}" (result)
        : [port] "{dx}" (port),
    );
    return result;
}
