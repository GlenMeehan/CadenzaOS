// src/kernel/ui/prompt.zig
//
// Simple blocking confirmation prompt.
//
// Displays a message and waits for the user to press:
//   • Y / y  -> confirm (true)
//   • N / n  -> decline (false)
//
// Input is taken from the keyboard queue (keyboard.readChar), the same
// queue the shell reads, so the answer is consumed and cannot reappear
// as typed input at the next prompt.

const vga = @import("../vga.zig");
const keyboard = @import("../inputs/keyboard.zig");

/// Display a yes/no prompt and wait for a user response.
///
/// Returns:
///   • true  if the user presses Y or y
///   • false if the user presses N or n
///
/// Any other key is consumed and ignored. This function blocks until a
/// valid response is received.
pub fn confirm(message: []const u8) bool {
    vga.writeString("\n", 0x07, 0);
    vga.writeString(message, 0x0E, 0); // Yellow prompt text
    vga.writeString(" (y/n): ", 0x0E, 0);

    // Discard anything typed before the prompt appeared, so stale input
    // does not immediately answer it.
    while (keyboard.readChar() != null) {}

    while (true) {
        if (keyboard.readChar()) |input| {
            if (input == 'y' or input == 'Y') {
                vga.writeString("y\n", 0x0A, 0); // Green confirmation
                return true;
            }

            if (input == 'n' or input == 'N') {
                vga.writeString("n\n", 0x0C, 0); // Red rejection
                return false;
            }

            // Some other key: it has been consumed. Look again at once.
            continue;
        }

        // Queue empty: sleep until the next interrupt arrives rather than
        // spinning while waiting for input.
        asm volatile ("hlt");
    }
}
