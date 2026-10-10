// src/kernel/console.zig
//
// Unified console output layer.
//
// Mirrors output to both the VGA display and the serial port so that
// interactive users and external debugging tools observe the same
// console stream.
//
// Kernel code should generally use this module instead of calling
// vga.writeString(), vga.putChar(), or serial routines directly.

const vga = @import("vga.zig");
const serial = @import("drivers/serial.zig");
const irupts = @import("irupts.zig");

/// Global console lock used to serialize multi-context console access.
pub var console_lock = irupts.IrqSpinLock{};

/// Write a string to both VGA and serial outputs.
pub fn writeString(s: []const u8, fg: u8, bg: u8) void {
    vga.writeString(s, fg, bg);
    serial.writeString(s);
}

/// Write a string without any higher-level terminal processing.
///
/// Output is mirrored to both VGA and serial destinations.
pub fn writeRaw(s: []const u8, fg: u8, bg: u8) void {
    vga.writeRaw(s, fg, bg);
    serial.writeString(s);
}

/// Write a single character to both VGA and serial outputs.
pub fn putChar(c: u8, fg: u8, bg: u8) void {
    vga.putChar(c, fg, bg);
    serial.putChar(c);
}

/// Write text at a fixed VGA screen location.
///
/// Serial output is intentionally suppressed because fixed-position
/// screen updates (status indicators, debug markers, etc.) do not
/// map cleanly to a linear serial terminal.
pub fn writeStringAt(row: u16, col: u16, s: []const u8, fg: u8, bg: u8) void {
    vga.writeStringAt(row, col, s, fg, bg);
}

pub fn clearScreen(fg: u8, bg: u8) void {
    vga.clearScreen(fg, bg);

    // Serial terminals cannot be synchronised with the VGA framebuffer,
    // so emit a marker indicating that the visible screen was cleared.
    serial.writeString("\r\n--- screen cleared ---\r\n");
}
