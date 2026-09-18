// src/kernel/splash.zig

const fb = @import("framebuffer.zig");
const vga = @import("vga.zig");
const logo = @import("logo.zig");
const serial = @import("drivers/serial.zig");

pub var enabled: bool = true;
var splash_active: bool = false;


const COLOR_BG: u32     = 0x1A100F; // Dark Charcoal
const COLOR_TEXT: u32   = 0xCCCCCC; // Off-white
const COLOR_BORDER: u32 = 0x555555; // Grey Border
const COLOR_FILL: u32   = 0x00AA00; // Green Fill

// Helper to convert standard 0xRRGGBB hex values into dynamically packed hardware colors
inline fn packHex(hex_rgb: u32) u32 {
    const r: u8 = @truncate((hex_rgb >> 16) & 0xFF);
    const g: u8 = @truncate((hex_rgb >> 8) & 0xFF);
    const b: u8 = @truncate(hex_rgb & 0xFF);
    return fb.packColor(r, g, b);
}

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



pub fn init() void {
    if (!vga.graphics_mode or !enabled) return;

    if (fb.fb_width == 0 or fb.fb_height == 0) return;

    splash_active = true;

    fb.fillRect(0, 0, fb.fb_width, fb.fb_height, COLOR_BG);

    const center_x = fb.fb_width / 2;
    const center_y = fb.fb_height / 2;

    // Choose a display size for the logo — e.g. a third of the screen's shorter dimension,
    // capped so it doesn't dominate very large screens.
    const target_size = @min(fb.fb_width, fb.fb_height) / 1;

    const half_logo_w = target_size / 2;
    const half_logo_h = target_size / 2;

    const logo_x = if (center_x >= half_logo_w) center_x - half_logo_w else 0;
    const logo_y = if (center_y >= half_logo_h + 10) center_y - half_logo_h - 10 else 0;

    fb.drawImageScaled(
        logo_x, logo_y,
        logo.LOGO_WIDTH, logo.LOGO_HEIGHT,   // source (128x128)
    target_size, target_size,             // destination (computed)
    logo.logo_data,
    );

    const bar_w: u32 = 300;
    const bar_h: u32 = 18;
    const bar_x = if (center_x >= bar_w / 2) center_x - (bar_w / 2) else 0;
    const bar_y = center_y + 80;
    fb.drawRectOutline(bar_x, bar_y, bar_w, bar_h, COLOR_BORDER);
}


pub fn updateProgress(percent: u8, status_msg: []const u8) void {
    if (!vga.graphics_mode or !enabled or !splash_active) return;
    if (fb.fb_width == 0 or fb.fb_height == 0) return;

    const center_x = fb.fb_width / 2;
    const center_y = fb.fb_height / 2;

    const bar_w: u32 = 300;
    const bar_h: u32 = 18;
    const bar_x = if (center_x >= bar_w / 2) center_x - (bar_w / 2) else 0;
    const bar_y = center_y + 80;

    // Inner progress fill (clamp percentage to 100)
    const valid_percent: u32 = @min(@as(u32, percent), 100);
    const fill_w = (valid_percent * (bar_w - 4)) / 100;
    if (fill_w > 0) {
        fb.fillRect(bar_x + 2, bar_y + 2, fill_w, bar_h - 4, COLOR_FILL);
    }

    // Erase and update status line
    const msg_y = bar_y + 28;
    const clear_x = if (center_x >= 200) center_x - 200 else 0;
    fb.fillRect(clear_x, msg_y, 400, 16, COLOR_BG);

    const msg_len: u32 = @intCast(@min(status_msg.len, 50));
    const text_half_w = (msg_len * 8) / 2;
    const msg_px = if (center_x >= text_half_w) center_x - text_half_w else 0;

    fb.drawStringAtPixel(msg_px, msg_y, status_msg, COLOR_TEXT, COLOR_BG);
}

pub fn dismiss() void {
    if (!vga.graphics_mode or !splash_active) return;

    splash_active = false;

    // Clear canvas to black and align cursor for shell
    fb.clearScreen(15, 0);
    fb.cursor_col = 0;
    fb.cursor_row = 0;
}

pub fn pause() void {
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn delay_crude(iterations: u64) void {
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        asm volatile ("nop");
    }
}
