// src/kernel/tss.zig
//
// Task State Segment (TSS) initialisation for x86_64 long mode.
//
// Responsibilities:
//   • Define the x86_64 TSS structure
//   • Configure interrupt-stack entries (IST)
//   • Disable the I/O permission bitmap
//   • Initialise the kernel TSS used by interrupt handling
//
const memory = @import("memory.zig");

/// Physical location reserved for the kernel TSS.
const TSS_PHYS_ADDR: usize = 0x20000;

/// Top of the dedicated IST1 interrupt stack.
///
/// This stack is used by interrupt gates configured to switch onto
/// IST entry 1, providing a known-good stack during interrupt entry.
const IST1_STACK_TOP: usize = 0x29000;

/// x86_64 Task State Segment.
///
/// In long mode the TSS is primarily used to provide alternate
/// interrupt stacks via the Interrupt Stack Table (IST).
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

    /// Offset of the I/O permission bitmap.
    ///
    /// Setting this to the size of the TSS effectively disables the
    /// bitmap by placing it beyond the end of the structure.
    io_map_base: u16 = 0,
};

/// Initialise the kernel Task State Segment.
///
/// The TSS is cleared, IST1 is configured to use the dedicated
/// interrupt stack, and the I/O permission bitmap is disabled.
pub fn init() void {
    const tss_ptr =
    @as(*volatile TSS, @ptrFromInt(memory.physToVirt(TSS_PHYS_ADDR)));

    tss_ptr.* = TSS{};

    // Configure the first Interrupt Stack Table entry.
    tss_ptr.ist1 = memory.physToVirt(IST1_STACK_TOP);

    // Disable the I/O permission bitmap.
    tss_ptr.io_map_base = @sizeOf(TSS);
}
