// src/kernel/system.zig

const port = @import("port_io.zig");

pub fn shutdown() noreturn {
    // QEMU/Bochs poweroff
    port.outw(0x604, 0x2000);

    // Fallback: halt forever
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn reboot() noreturn {
    // Full hardware reset via Reset Control Register
    port.outb(0xCF9, 0x02); // Request reset
    port.outb(0xCF9, 0x06); // Full reset

    // Fallback: keyboard controller reset
    port.outb(0x64, 0xFE);

    // Final fallback: halt
    while (true) {
        asm volatile ("hlt");
    }
}
