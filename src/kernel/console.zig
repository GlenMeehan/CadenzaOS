// src/kernel/console.zig
//
// Unified console output — fans out to both VGA and serial simultaneously.
// Use this instead of calling vga.writeString/putChar directly so that
// all output appears on both the VGA display and the serial port.

const vga = @import("vga.zig");
const serial = @import("drivers/serial.zig");

pub fn writeString(s: []const u8, fg: u8, bg: u8) void {
    vga.writeString(s, fg, bg);
    serial.writeString(s);
}

pub fn writeRaw(s: []const u8, fg: u8, bg: u8) void {
    vga.writeRaw(s, fg, bg);
    serial.writeString(s);
}

pub fn putChar(c: u8, fg: u8, bg: u8) void {
    vga.putChar(c, fg, bg);
    serial.putChar(c);
}

pub fn writeStringAt(row: u16, col: u16, s: []const u8, fg: u8, bg: u8) void {
    vga.writeStringAt(row, col, s, fg, bg);
    // Skip serial for writeStringAt — it's used for fixed-position
    // debug indicators (vga.step etc.) that don't make sense on serial
}

pub fn clearScreen(fg: u8, bg: u8) void {
    vga.clearScreen(fg, bg);
    serial.writeString("\r\n--- screen cleared ---\r\n");
}
