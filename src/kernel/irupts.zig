// src/kernel/irupts.zig


const vga = @import("vga.zig");
const io = @import("port_io.zig");
const conv = @import("convert.zig");

pub var ticks: u64 = 0;

pub export fn irq0_handler() callconv(.c) void {
    ticks += 1;

    if (ticks % 100 == 0) {
        var buf: [18]u8 = undefined;
        const hex = conv.toHex(u64, ticks, &buf);

        vga.writeStringAt(2, 53, "Ticks: ", 15, 0);
        vga.writeStringAt(2, 60, hex, 15, 0);
    }

    io.outb(0x20, 0x20);
}

pub export fn irq1_handler() callconv(.c) void {
    const scancode = io.inb(0x60);

    //Temporary debug output
    var buf: [18]u8 = undefined;
    const hex = conv.toHex(u8, scancode, &buf);
    vga.writeStringAt(3, 53, "Key", 15, 0);
    vga.writeStringAt(3, 58, hex, 15, 0);

    io.outb(0x20, 0x20); // EOI
}

var mouse_index: u8 = 0;
var mouse_packet: [3]u8 = .{0, 0, 0};
var count: u8 = 0;

pub export fn irq12_handler() callconv(.c) void {


    count +=1;
    var buf0: [18]u8 = undefined;
    vga.writeStringAt(6, 53, conv.toHex(u8, count, &buf0), 15, 0);

    const byte = io.inb(0x60);

    mouse_packet[mouse_index] = byte;
    mouse_index +=1;

    if (mouse_index == 3) {
        mouse_index = 0;

        //Decode packet
        //const status = mouse_packet[0];
        const raw_dx = mouse_packet[1];
        const raw_dy = mouse_packet[2] ;

        //Convert to signed 8-bit movement
        const dx = @as(i8, @bitCast(raw_dx));
        const dy = @as(i8, @bitCast(raw_dy));

        const dx_u8: u8 = @bitCast(dx);
        const dy_u8: u8 = @bitCast(dy);

        var buf1: [18]u8 = undefined;
        var buf2: [18]u8 = undefined;


        //Example debug output
        vga.writeStringAt(4, 53, "Mouse dx", 15, 0);
        vga.writeStringAt(4, 63, conv.toHex(u8, dx_u8, &buf1), 15, 0);

        vga.writeStringAt(5, 53, "Mouse dy", 15, 0);
        vga.writeStringAt(5, 63, conv.toHex(u8, dy_u8, &buf2), 15, 0);
    }
    io.outb(0xA0, 0x20); // EOI slave
    io.outb(0x20, 0x20); // EOI master
}
