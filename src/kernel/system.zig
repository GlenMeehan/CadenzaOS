// src/kernel/system.zig
//
// System‑level power control for QEMU/Bochs and real hardware.
// Provides:
//   • shutdown() — request ACPI poweroff, fallback to CPU halt
//   • reboot()   — request hardware reset, fallback to keyboard controller reset
//
// These functions never return.

const port = @import("port_io.zig");

/// Shut down the machine (QEMU/Bochs ACPI poweroff).
/// Falls back to halting the CPU forever.
pub fn shutdown() noreturn {
    // QEMU/Bochs ACPI poweroff:
    // Writing 0x2000 to port 0x604 triggers a poweroff event.
    port.outw(0x604, 0x2000);

    // Fallback: halt forever
    while (true) {
        asm volatile ("hlt");
    }
}

/// Reboot the machine using the standard Reset Control Register.
/// Falls back to keyboard controller reset, then halts.
pub fn reboot() noreturn {
    // Full hardware reset via Reset Control Register (0xCF9):
    //   0x02 = request reset
    //   0x06 = full reset (system + CPU)
    port.outb(0xCF9, 0x02);
    port.outb(0xCF9, 0x06);

    // Fallback: keyboard controller reset (legacy)
    port.outb(0x64, 0xFE);

    // Final fallback: halt forever
    while (true) {
        asm volatile ("hlt");
    }
}
