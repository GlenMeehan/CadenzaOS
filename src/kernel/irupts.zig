// src/kernel/irupts.zig
//
// Hardware interrupt handlers for:
//   • IRQ0  — PIT timer
//   • IRQ1  — PS/2 keyboard
//   • IRQ12 — PS/2 mouse
//
// All handlers:
//   • Perform minimal work
//   • Update state / forward to subsystem
//   • Send EOI to PIC (master or master+slave)

const vga = @import("vga.zig");
const io = @import("port_io.zig");
const conv = @import("convert.zig");
const keyboard = @import("inputs/keyboard.zig");

pub var ticks: u64 = 0;

// -----------------------------------------------------------------------------
//  IRQ0 — TIMER
// -----------------------------------------------------------------------------

pub export fn irq0_handler() callconv(.c) void {
    ticks += 1;

    // Debug: update tick counter every 100 ticks
    if (ticks % 100 == 0) {
        var buf: [18]u8 = undefined;
        const hex = conv.toHex(u64, ticks, &buf);

        vga.writeStringAt(0, 57, "Ticks: ", 15, 0);
        vga.writeStringAt(0, 64, hex, 15, 0);
    }

    // End of interrupt (master PIC)
    io.outb(0x20, 0x20);
}

// -----------------------------------------------------------------------------
//  IRQ1 — KEYBOARD
// -----------------------------------------------------------------------------

pub export fn irq1_handler() callconv(.c) void {
    const scancode = io.inb(0x60);
    keyboard.handleScancode(scancode);

    // EOI (master PIC)
    io.outb(0x20, 0x20);
}

// -----------------------------------------------------------------------------
//  IRQ12 — MOUSE
// -----------------------------------------------------------------------------

var mouse_index: u8 = 0;
var mouse_packet: [3]u8 = .{0, 0, 0};
var count: u8 = 0;

pub export fn irq12_handler() callconv(.c) void {
    // Debug counter
    count += 1;
    var buf0: [18]u8 = undefined;
    vga.writeStringAt(6, 53, conv.toHex(u8, count, &buf0), 15, 0);

    // Read next byte of PS/2 mouse packet
    const byte = io.inb(0x60);
    mouse_packet[mouse_index] = byte;
    mouse_index += 1;

    // Full 3‑byte packet received?
    if (mouse_index == 3) {
        mouse_index = 0;

        const raw_dx = mouse_packet[1];
        const raw_dy = mouse_packet[2];

        // Convert to signed deltas
        const dx = @as(i8, @bitCast(raw_dx));
        const dy = @as(i8, @bitCast(raw_dy));

        const dx_u8: u8 = @bitCast(dx);
        const dy_u8: u8 = @bitCast(dy);

        var buf1: [18]u8 = undefined;
        var buf2: [18]u8 = undefined;

        // Debug output
        vga.writeStringAt(4, 53, "Mouse dx", 15, 0);
        vga.writeStringAt(4, 63, conv.toHex(u8, dx_u8, &buf1), 15, 0);

        vga.writeStringAt(5, 53, "Mouse dy", 15, 0);
        vga.writeStringAt(5, 63, conv.toHex(u8, dy_u8, &buf2), 15, 0);
    }

    // EOI: slave PIC first, then master PIC
    io.outb(0xA0, 0x20); // slave
    io.outb(0x20, 0x20); // master
}
