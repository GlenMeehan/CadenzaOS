// src/kernel/splash.zig
//
// Graphical boot splash screen support.
//
// Responsibilities:
//   • Display the startup logo
//   • Render a boot progress bar
//   • Display status messages during kernel initialisation
//   • Transition cleanly to the normal framebuffer console
//
const fb = @import("framebuffer.zig");
const vga = @import("vga.zig");
const logo = @import("logo.zig");
const serial = @import("drivers/serial.zig");

/// Globally enable or disable splash-screen rendering.
pub var enabled: bool = true;

/// Tracks whether the splash screen is currently visible.
var splash_active: bool = false;

// -----------------------------------------------------------------------------
//  SPLASH SCREEN COLOUR PALETTE
// -----------------------------------------------------------------------------

const COLOR_BG: u32     = 0x1A100F; // Dark charcoal background
const COLOR_TEXT: u32   = 0xCCCCCC; // Off-white text
const COLOR_BORDER: u32 = 0x555555; // Progress-bar border
const COLOR_FILL: u32   = 0x00AA00; // Progress-bar fill

/// Convert a standard 0xRRGGBB colour value into the framebuffer's
/// hardware-specific packed pixel format.
inline fn packHex(hex_rgb: u32) u32 {
    const r: u8 = @truncate((hex_rgb >> 16) & 0xFF);
    const g: u8 = @truncate((hex_rgb >> 8) & 0xFF);
    const b: u8 = @truncate(hex_rgb & 0xFF);

    return fb.packColor(r, g, b);
}

/// Write an unsigned decimal value to the serial console.
///
/// Used primarily for low-level diagnostics.
fn printDec(n: u32) void {
    var tmp = n;
    var buf: [16]u8 = undefined;
    var i: usize = buf.len;

    if (tmp == 0) {
        serial.writeString("0");
        return;
    }

    while (tmp > 0) : (tmp /= 10) {
        i -= 1;
        buf[i] = @as(u8, @intCast((tmp % 10) + '0'));
    }

    serial.writeString(buf[i..]);
}

/// Initialise and display the graphical startup splash screen.
///
/// Does nothing when graphics mode is unavailable or splash rendering
/// has been disabled.
pub fn init() void {
    if (!vga.graphics_mode or !enabled) return;

    if (fb.fb_width == 0 or fb.fb_height == 0) return;

    splash_active = true;

    // Clear the framebuffer using the splash-screen background colour.
    fb.fillRect(0, 0, fb.fb_width, fb.fb_height, COLOR_BG);

    const center_x = fb.fb_width / 2;
    const center_y = fb.fb_height / 2;

    // Scale the logo relative to the framebuffer dimensions so it
    // remains appropriately sized across different resolutions.
    const target_size = @min(fb.fb_width, fb.fb_height) / 1;

    const half_logo_w = target_size / 2;
    const half_logo_h = target_size / 2;

    const logo_x =
    if (center_x >= half_logo_w)
        center_x - half_logo_w
        else
            0;

    const logo_y =
    if (center_y >= half_logo_h + 10)
        center_y - half_logo_h - 10
        else
            0;

    // Render the embedded splash image.
    fb.drawImageScaled(
        logo_x,
        logo_y,
        logo.LOGO_WIDTH,
        logo.LOGO_HEIGHT,
        target_size,
        target_size,
        logo.logo_data,
    );

    // Create the progress-bar outline.
    const bar_w: u32 = 300;
    const bar_h: u32 = 18;

    const bar_x =
    if (center_x >= bar_w / 2)
        center_x - (bar_w / 2)
        else
            0;

    const bar_y = center_y + 80;

    fb.drawRectOutline(bar_x, bar_y, bar_w, bar_h, COLOR_BORDER);
}

/// Update splash-screen progress information.
///
/// The progress bar is filled to the requested percentage and the
/// accompanying status message is refreshed.
pub fn updateProgress(percent: u8, status_msg: []const u8) void {
    if (!vga.graphics_mode or !enabled or !splash_active) return;
    if (fb.fb_width == 0 or fb.fb_height == 0) return;

    const center_x = fb.fb_width / 2;
    const center_y = fb.fb_height / 2;

    const bar_w: u32 = 300;
    const bar_h: u32 = 18;

    const bar_x =
    if (center_x >= bar_w / 2)
        center_x - (bar_w / 2)
        else
            0;

    const bar_y = center_y + 80;

    // Clamp progress values to a maximum of 100%.
    const valid_percent: u32 = @min(@as(u32, percent), 100);

    const fill_w = (valid_percent * (bar_w - 4)) / 100;

    if (fill_w > 0) {
        fb.fillRect(
            bar_x + 2,
            bar_y + 2,
            fill_w,
            bar_h - 4,
            COLOR_FILL,
        );
    }

    // Clear and redraw the current status message.
    const msg_y = bar_y + 28;

    const clear_x =
    if (center_x >= 200)
        center_x - 200
        else
            0;

    fb.fillRect(clear_x, msg_y, 400, 16, COLOR_BG);

    const msg_len: u32 = @intCast(@min(status_msg.len, 50));
    const text_half_w = (msg_len * 8) / 2;

    const msg_px =
    if (center_x >= text_half_w)
        center_x - text_half_w
        else
            0;

    fb.drawStringAtPixel(
        msg_px,
        msg_y,
        status_msg,
        COLOR_TEXT,
        COLOR_BG,
    );
}

/// Remove the splash screen and return control to the normal
/// framebuffer console.
pub fn dismiss() void {
    if (!vga.graphics_mode or !splash_active) return;

    splash_active = false;

    // Clear the framebuffer and reset text output state.
    fb.clearScreen(15, 0);
    fb.cursor_col = 0;
    fb.cursor_row = 0;
}

/// Halt execution indefinitely.
///
/// Useful when inspecting splash-screen rendering behaviour during
/// development and debugging.
pub fn pause() void {
    while (true) {
        asm volatile ("hlt");
    }
}

/// Crude busy-wait delay.
///
/// Intended only for visual timing effects during early boot where
/// no scheduler- or timer-based delay mechanism is yet available.
pub fn delay_crude(iterations: u64) void {
    var i: u64 = 0;

    while (i < iterations) : (i += 1) {
        asm volatile ("nop");
    }
}
