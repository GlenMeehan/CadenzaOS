//src/kernel/drivers/serial.zig

pub fn readByte() ?u8 {
    const LSR = @as(*volatile u8, @ptrFromInt(0x3F8 + 5)); // Line Status Register
    const RBR = @as(*volatile u8, @ptrFromInt(0x3F8 + 0)); // Receiver Buffer Register

    // Bit 0 of LSR = data ready
    if ((LSR.* & 1) == 0) return null;

    return RBR.*;
}
