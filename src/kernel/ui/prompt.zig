// src/kernel/prompt.zig

const vga = @import("../vga.zig");
const keyboard = @import("../inputs/keyboard.zig");

pub fn confirm(message: []const u8) bool {
    vga.writeString("\n", 0x07, 0);
    vga.writeString(message, 0x0E, 0); // Yellow warning message
    vga.writeString(" (y/n): ", 0x0E, 0);

    keyboard.last_char = 0; // Clear previous input

    while (true) {
        const input = keyboard.last_char;
        if (input == 'y' or input == 'Y') {
            vga.writeString("y\n", 0x0A, 0);
            return true;
        }
        if (input == 'n' or input == 'N') {
            vga.writeString("n\n", 0x0C, 0);
            return false;
        }
        // Save CPU cycles while waiting for the user to think
        asm volatile ("hlt");
    }
}
