// src/kernel/prompt.zig
//
// Simple blocking confirmation prompt.
//
// Displays a message and waits for the user to press:
//   • Y / y  -> confirm (true)
//   • N / n  -> decline (false)
//
// Input is currently obtained via keyboard.last_char, making this
// suitable for early boot and simple kernel utilities where a full
// input-event pipeline is not required.

const vga = @import("../vga.zig");
const keyboard = @import("../inputs/keyboard.zig");

/// Display a yes/no prompt and wait for a user response.
///
/// Returns:
///   • true  if the user presses Y or y
///   • false if the user presses N or n
///
/// This function blocks until a valid response is received.
pub fn confirm(message: []const u8) bool {
    vga.writeString("\n", 0x07, 0);
    vga.writeString(message, 0x0E, 0); // Yellow prompt text
    vga.writeString(" (y/n): ", 0x0E, 0);

    // Clear any previously received keystroke so stale input
    // does not immediately satisfy the prompt.
    keyboard.last_char = 0;

    while (true) {
        const input = keyboard.last_char;

        if (input == 'y' or input == 'Y') {
            vga.writeString("y\n", 0x0A, 0); // Green confirmation
            return true;
        }

        if (input == 'n' or input == 'N') {
            vga.writeString("n\n", 0x0C, 0); // Red rejection
            return false;
        }

        // Sleep until the next interrupt arrives rather than
        // continuously spinning while waiting for input.
        asm volatile ("hlt");
    }
}
