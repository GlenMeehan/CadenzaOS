//src/kernel/tss.zig

const memory = @import("memory.zig");

const TSS_PHYS_ADDR: usize = 0x20000;
const IST1_STACK_TOP: usize = 0x25000;

pub const TSS = packed struct {
    reserved0: u32 = 0,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    reserved1: u64 = 0,
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved2: u64 = 0,
    reserved3: u16 = 0,
    io_map_base: u16 = 0,
};

pub fn init() void {
    const tss_ptr = @as(*volatile TSS, @ptrFromInt(memory.physToVirt(TSS_PHYS_ADDR)));
    tss_ptr.* = TSS{};
    tss_ptr.ist1 = memory.physToVirt(IST1_STACK_TOP);
    tss_ptr.io_map_base = @sizeOf(TSS);
}
