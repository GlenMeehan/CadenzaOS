// src/kernel/font.zig
//
// IBM 8x16 VGA bitmap font — extracted from default8x16.psfu.
// 256 characters, each 8 pixels wide and 16 pixels tall.
// Each character is 16 bytes — one byte per row.
// Within each byte, bit 7 (MSB) = leftmost pixel, bit 0 = rightmost pixel.
// A set bit = foreground pixel, clear bit = background pixel.

pub const GLYPH_WIDTH:  u32 = 8;
pub const GLYPH_HEIGHT: u32 = 16;
pub const GLYPH_COUNT:  u32 = 256;
pub const GLYPH_BYTES:  u32 = GLYPH_HEIGHT; // bytes per glyph = 16

/// Raw glyph bitmap data — 4096 bytes total.
/// Index with: glyphs[char_code * GLYPH_HEIGHT + row]
/// to get the 8-pixel row bitmap for a given character.
pub const glyphs: [4096]u8 = @embedFile("font8x16.bin").*;
