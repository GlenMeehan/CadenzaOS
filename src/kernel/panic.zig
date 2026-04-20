// src/kernel/panic.zig
//
// Kernel panic handler.
// This overrides Zig's default panic function.
// Behaviour:
//   • Clear screen to red background
//   • Print panic banner + message
//   • Optionally print return address
//   • Halt CPU forever (cli + hlt)

const std = @import("std");
const vga = @import("vga.zig");
const conv = @import("convert.zig");

pub fn panic(
    message: []const u8,
    _: ?*std.builtin.StackTrace, // stack traces not supported yet
    ret_addr: ?usize,
) noreturn {
    // VGA text buffer at physical address 0xB8000
    const vga_ptr = @as([*]volatile u16, @ptrFromInt(0xB8000));

    // Clear screen to red background with bright white text.
    // 0x4F20 = (bg=4 red, fg=F bright white, char=' ')
    var i: usize = 0;
    while (i < 80 * 25) : (i += 1) {
        vga_ptr[i] = 0x4F20;
    }

    // Panic banner
    vga.writeStringAt(10, 0, "KERNEL PANIC!", 0x0F, 0x04);

    // Panic message
    vga.writeStringAt(12, 0, message, 0x0F, 0x04);

    // Optional return address (if Zig provided one)
    if (ret_addr) |addr| {
        var buf: [16]u8 = undefined;
        vga.writeStringAt(14, 0, "At address: ", 0x0F, 0x04);
        vga.writeStringAt(14, 12, conv.toHex(u64, addr, &buf), 0x0F, 0x04);
    }

    // Halt CPU forever
    while (true) {
        asm volatile ("cli; hlt");
    }
}
