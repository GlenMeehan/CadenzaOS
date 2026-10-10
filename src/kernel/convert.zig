// src/kernel/convert.zig
//
// Lightweight integer formatting and parsing helpers.
//
// These routines avoid std.fmt so they can be used in early boot,
// interrupt handlers, and other freestanding kernel code.
//
// Provides:
//   • toHex()    — fixed-width uppercase hexadecimal (no "0x" prefix)
//   • u32ToStr() — decimal conversion for u32 values
//   • u64ToStr() — decimal conversion for u64 values
//   • strToU32() — decimal ASCII parsing

// -----------------------------------------------------------------------------
//  FIXED-WIDTH HEX CONVERSION
// -----------------------------------------------------------------------------

/// Convert an integer to a fixed-width uppercase hexadecimal string.
///
/// No "0x" prefix is emitted. The caller must provide a sufficiently
/// large output buffer.
///
/// Example:
///     var buf: [16]u8 = undefined;
///     const hex = toHex(u64, 0xDEADBEEF, buf[0..]);
///     // hex = "00000000DEADBEEF"
pub fn toHex(comptime T: type, value: T, buf: []u8) []u8 {

    // Ensure T is an integer type.
    const info = @typeInfo(T);

    const bits = switch (info) {
        .int => |intinfo| intinfo.bits,
        else => @compileError("toHex only supports integer types"),
    };

        // One hexadecimal digit represents four bits.
        const digits = bits / 4;

        if (buf.len < digits)
            @panic("hex buffer too small");

    // Convert each nibble from most-significant to least-significant.
    var i: usize = 0;

    while (i < digits) : (i += 1) {
        const shift_bits = (digits - 1 - i) * 4;

        // Zig requires the shift amount type to be wide enough to
        // represent the valid shift range for the source integer.
        const ShiftType =
        if (bits == 64) u6
            else if (bits == 32) u5
                else if (bits == 16) u4
                    else u3;

                    const shift_amt = @as(ShiftType, @intCast(shift_bits));

        // Extract the current 4-bit nibble.
        const nibble = @as(u4, @truncate((value >> shift_amt) & 0xF));

        // Convert nibble -> ASCII hexadecimal digit.
        buf[i] = "0123456789ABCDEF"[nibble];
    }

    return buf[0..digits];
}

// -----------------------------------------------------------------------------
//  DECIMAL CONVERSION (u32)
// -----------------------------------------------------------------------------

/// Convert a u32 to decimal ASCII.
///
/// Writes digits into the supplied buffer from right to left and
/// returns the slice containing the formatted result.
pub fn u32ToStr(buf: *[16]u8, value: u32) []const u8 {
    var i: usize = buf.len;
    var v = value;

    if (v == 0) {
        buf[buf.len - 1] = '0';
        return buf[buf.len - 1 ..];
    }

    while (v > 0 and i > 0) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
        v /= 10;
    }

    return buf[i..];
}

// -----------------------------------------------------------------------------
//  DECIMAL PARSING (ASCII → u32)
// -----------------------------------------------------------------------------

/// Parse an ASCII decimal string into a u32.
///
/// Returns error.InvalidDigit if any non-decimal character is
/// encountered.
pub fn strToU32(s: []const u8) !u32 {
    var value: u32 = 0;

    for (s) |ch| {
        if (ch < '0' or ch > '9')
            return error.InvalidDigit;

        const digit: u32 = @as(u32, ch - '0');
        value = value * 10 + digit;
    }

    return value;
}

/// Convert a u64 to decimal ASCII.
///
/// Writes digits into the supplied buffer from right to left and
/// returns the slice containing the formatted result.
pub fn u64ToStr(buf: *[21]u8, value: u64) []const u8 {
    var i: usize = buf.len;
    var v = value;

    if (v == 0) {
        buf[buf.len - 1] = '0';
        return buf[buf.len - 1 ..];
    }

    while (v > 0 and i > 0) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
        v /= 10;
    }

    return buf[i..];
}
