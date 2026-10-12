// src/kernel/panic.zig
//
// Kernel panic handler.
//
// This module provides the kernel's final unrecoverable error path,
// replacing Zig's default panic implementation.
//
// Behaviour:
//   • Clear the display using high-visibility panic colours
//   • Display a panic banner and diagnostic message
//   • Optionally display a return address
//   • Halt the processor permanently
//
const std = @import("std");
const vga = @import("vga.zig");
const conv = @import("convert.zig");

/// Handle a fatal kernel error.
///
/// Once entered, this function never returns. Diagnostic information
/// is displayed to the user before the processor is halted.
pub fn panic(
    msg: []const u8,
    trace: ?*anyopaque,
    return_address: ?usize,
) noreturn {
    _ = trace;

    // Direct VGA text buffer access.
    const vga_ptr = @as([*]volatile u16, @ptrFromInt(0xB8000));

    // Fill the entire screen with red-background panic cells using
    // bright white foreground text.
    //
    // 0x4F20:
    //   bg = 0x4 (red)
    //   fg = 0xF (bright white)
    //   ch = ' '
    var i: usize = 0;
    while (i < 80 * 25) : (i += 1) {
        vga_ptr[i] = 0x4F20;
    }

    // Display the panic banner.
    vga.writeStringAt(10, 0, "KERNEL PANIC!", 0x0F, 0x04);

    // Display the panic message supplied by the caller.
    vga.writeStringAt(12, 0, message, 0x0F, 0x04);

    // Display the return address when available. This can assist
    // with fault isolation during kernel debugging.
    if (ret_addr) |addr| {
        var buf: [16]u8 = undefined;

        vga.writeStringAt(14, 0, "At address: ", 0x0F, 0x04);
        vga.writeStringAt(
            14,
            12,
            conv.toHex(u64, addr, &buf),
                          0x0F,
                          0x04,
        );
    }

    // Disable interrupts and halt permanently.
    while (true) {
        asm volatile ("cli; hlt");
    }
}
