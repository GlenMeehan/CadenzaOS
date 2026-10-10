// src/kernel/font.zig
//
// IBM VGA 8x16 bitmap font.
//
// The font contains 256 glyphs, each 8 pixels wide by 16 pixels high.
// Every glyph occupies 16 consecutive bytes, with one byte describing
// a single row of 8 pixels.
//
// Bit layout within a row byte:
//
//   Bit 7 (MSB)  -> leftmost pixel
//   Bit 0 (LSB)  -> rightmost pixel
//
// A set bit represents a foreground pixel.
// A cleared bit represents a background pixel.
//
pub const GLYPH_WIDTH:  u32 = 8;
pub const GLYPH_HEIGHT: u32 = 16;
pub const GLYPH_COUNT:  u32 = 256;

/// Number of bytes used to store a single glyph.
///
/// Since each glyph is 16 rows high and each row occupies one byte,
/// every glyph consumes 16 bytes of storage.
pub const GLYPH_BYTES:  u32 = GLYPH_HEIGHT;

/// Raw bitmap data for all 256 glyphs.
///
/// Layout:
///   Glyph 0   -> bytes   0 .. 15
///   Glyph 1   -> bytes  16 .. 31
///   ...
///   Glyph 255 -> bytes 4080 .. 4095
///
/// To obtain the bitmap for a specific row of a character:
///
///     glyphs[char_code * GLYPH_HEIGHT + row]
///
/// The resulting byte contains the 8-pixel bitmap for that row.
pub const glyphs: [4096]u8 = @embedFile("font8x16.bin").*;
