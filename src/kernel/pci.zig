// src/kernel/pci.zig
//
// Minimal PCI configuration-space access (legacy 0xCF8/0xCFC mechanism).

const port = @import("port_io.zig");

pub const IdeInfo = struct {
    prog_if: u8,
    bar0: u32,
    bar1: u32,
};

/// Read a 32-bit dword from PCI configuration space.
pub fn configRead32(bus: u8, dev: u8, func: u8, offset: u8) u32 {
    const addr: u32 = 0x8000_0000 |
        (@as(u32, bus) << 16) |
        (@as(u32, dev) << 11) |
        (@as(u32, func) << 8) |
        @as(u32, offset & 0xFC);

    port.outl(0xCF8, addr);
    return port.inl(0xCFC);
}

/// Find the first IDE controller (class 0x01, subclass 0x01) on bus 0.
pub fn findIde() ?IdeInfo {
    var dev: u8 = 0;
    while (dev < 32) : (dev += 1) {
        var func: u8 = 0;
        while (func < 8) : (func += 1) {
            const id = configRead32(0, dev, func, 0x00);
            if ((id & 0xFFFF) == 0xFFFF) continue; // nothing here


            const class_reg = configRead32(0, dev, func, 0x08);
            const class_code: u8 = @truncate(class_reg >> 24);
            const subclass: u8 = @truncate(class_reg >> 16);
            const prog_if: u8 = @truncate(class_reg >> 8);

            if (class_code == 0x01 and subclass == 0x01) {
                return .{
                    .prog_if = prog_if,
                    .bar0 = configRead32(0, dev, func, 0x10),
                    .bar1 = configRead32(0, dev, func, 0x14),
                };
            }
        }
    }
    return null;
}
