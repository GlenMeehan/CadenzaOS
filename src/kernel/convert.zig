// src/kernel/convert.zig
//
// Simple integer‑to‑hexadecimal conversion for fixed‑width integers.
// Produces an uppercase hex string with no "0x" prefix.
//
// Example:
//   var buf: [16]u8 = undefined;
//   const hex = toHex(u64, 0xDEADBEEF, buf[0..]);
//   // hex = "00000000DEADBEEF"
//
// This avoids std formatting to keep the kernel freestanding.

pub fn toHex(comptime T: type, value: T, buf: []u8) []u8 {
    // Ensure T is an integer type
    const info = @typeInfo(T);
    const bits = switch (info) {
        .int => |intinfo| intinfo.bits,
        else => @compileError("toHex only supports integer types"),
    };

        // One hex digit per 4 bits
        const digits = bits / 4;

        if (buf.len < digits)
            @panic("hex buffer too small");

    // Convert each nibble from most‑significant to least‑significant
    var i: usize = 0;
    while (i < digits) : (i += 1) {
        // Compute how far to shift to extract nibble i
        const shift_bits = (digits - 1 - i) * 4;

        // Shift amount type must be wide enough for the bit count
        const ShiftType =
        if (bits == 64) u6
            else if (bits == 32) u5
                else if (bits == 16) u4
                    else u3;

                    const shift_amt = @as(ShiftType, @intCast(shift_bits));

        // Extract nibble
        const nibble = @as(u4, @truncate((value >> shift_amt) & 0xF));

        // Lookup hex digit
        buf[i] = "0123456789ABCDEF"[nibble];
    }

    return buf[0..digits];
}

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

pub fn strToU32(s: []const u8) !u32 {
    var value: u32 = 0;

    for (s) |ch| {
        if (ch < '0' or ch > '9') return error.InvalidDigit;

        const digit: u32 = @as(u32, ch - '0');
        value = value * 10 + digit;
    }

    return value;
}
