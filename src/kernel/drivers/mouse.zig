//src/kernel/drivers/mouse.zig

const io = @import("../port_io.zig");

fn waitWrite() void {
    //Waituntil bit 1 (input buffer full) is clear
    while ((io.inb(0x64) & 0b10) != 0) {}

}

fn waitRead() void {
    //Waituntil bit 0 (output buffer full) is clear
    while ((io.inb(0x64) & 0b1) == 0) {}

}

fn mouseWrite(byte: u8) void {
    waitWrite();
    io.outb(0x64, 0xD4); // tell controller: next byte is for mouse
    waitWrite();
    io.outb(0x60, byte);
}

fn mouseRead() u8 {
    waitRead();
    return io.inb(0x60);
}

pub fn initMouse() void{
    //1. Enable the auxiliary PS/2 port
    waitWrite();
    io.outb(0x64, 0xA8);

    //2. Enable mouse IRQs in controller's config byte
    waitWrite();
    io.outb(0x64, 0x20); //Read command byte
    const status = blk: {
        waitRead();
        break: blk io.inb(0x60);
    };
    //Set bit 1 (enable IRQ12)
    waitWrite();
    io.outb(0x64, 0x60); // Write command byte
    waitWrite();
    io.outb(0x60, status | 0b10);

    //3. Reset mouse to defaults
    mouseWrite(0xF6);
    _ = mouseRead(); //ACK

    //4. Enable streaming mode
    mouseWrite(0xF4);
        _ = mouseRead(); //ACK
}
