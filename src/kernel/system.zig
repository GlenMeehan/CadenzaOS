// src/kernel/system.zig
//
// System power-control helpers.
//
// Provides:
//   • shutdown() — request system power-off
//   • reboot()   — request a hardware reset
//
// These routines target common emulator and PC-compatible hardware
// interfaces. If the requested operation fails, execution falls back
// to a permanent processor halt.
//
// Both functions are noreturn.
//
const port = @import("port_io.zig");

/// Request system shutdown.
///
/// Uses the ACPI-compatible power-off mechanism supported by
/// QEMU and Bochs. If power-off is unavailable, execution falls
/// back to a permanent CPU halt.
pub fn shutdown() noreturn {

    // QEMU/Bochs ACPI power-off.
    //
    // Writing 0x2000 to port 0x604 triggers an emulated ACPI
    // shutdown event.
    port.outw(0x604, 0x2000);

    // Final fallback if shutdown is unsupported.
    while (true) {
        asm volatile ("hlt");
    }
}

/// Request a system reboot.
///
/// Attempts a hardware reset using the standard Reset Control
/// Register. If that mechanism fails, a legacy keyboard-controller
/// reset is attempted before falling back to a permanent halt.
pub fn reboot() noreturn {

    // Modern hardware reset via the Reset Control Register.
    //
    // 0x02 = request reset
    // 0x06 = full system reset
    port.outb(0xCF9, 0x02);
    port.outb(0xCF9, 0x06);

    // Legacy keyboard-controller reset.
    port.outb(0x64, 0xFE);

    // Final fallback if all reset mechanisms fail.
    while (true) {
        asm volatile ("hlt");
    }
}
