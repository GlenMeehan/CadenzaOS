// src/kernel/idt.zig
//
// Interrupt Descriptor Table (IDT) support for x86_64 long mode.
//
// Responsibilities:
//   • Define the x86_64 IDT and IDTR structures
//   • Maintain the kernel's 256-entry Interrupt Descriptor Table
//   • Install handlers for selected CPU exceptions
//   • Provide a bridge between assembly stubs and Zig exception handling
//
// Notes:
//   • Interrupt Stack Tables (ISTs) are not currently used
//   • User-mode interrupt gates are not yet supported
//   • Hardware IRQ registration is handled separately
//   • Assembly stubs normalise exception data into a consistent
//     (vector, error_code) format before entering Zig code
//
const vga = @import("vga.zig");
const conv = @import("convert.zig");

extern fn load_idt(ptr: *const IDTR) void;

// -----------------------------------------------------------------------------
//  IDT DESCRIPTOR STRUCTURES
// -----------------------------------------------------------------------------

/// x86_64 interrupt gate descriptor.
///
/// The processor requires a 64-bit handler address to be split across
/// three separate fields within each IDT entry.
const IDTEntry = packed struct {
    offset_low:  u16,
    selector:    u16,
    ist:         u8,
    flags:       u8,
    offset_mid:  u16,
    offset_high: u32,
    reserved:    u32 = 0,
};

/// Interrupt Descriptor Table Register (IDTR).
///
/// Loaded with the lidt instruction to activate an Interrupt
/// Descriptor Table.
const IDTR = packed struct {
    limit: u16,
    base:  u64,
};

/// The kernel's Interrupt Descriptor Table.
///
/// x86 processors support 256 interrupt vectors. The table is aligned
/// to a 16-byte boundary for predictable low-level access and CPU
/// compatibility.
var idt: [256]IDTEntry align(16) = [_]IDTEntry{.{
    .offset_low = 0,
    .selector   = 0,
    .ist        = 0,
    .flags      = 0,
    .offset_mid = 0,
    .offset_high = 0,
    .reserved   = 0,
}} ** 256;

// -----------------------------------------------------------------------------
//  EXCEPTION DESCRIPTIONS
// -----------------------------------------------------------------------------

/// Human-readable names for standard CPU exception vectors.
///
/// Used when displaying fault information during exception handling
/// and early-kernel debugging.
const exception_names = [_][]const u8{
    "Division By Zero",                // 0
    "Debug",                           // 1
    "Non-Maskable Interrupt",          // 2
    "Breakpoint",                      // 3
    "Overflow",                        // 4
    "Bound Range Exceeded",            // 5
    "Invalid Opcode",                  // 6
    "Device Not Available",            // 7
    "Double Fault",                    // 8
    "Coprocessor Segment Overrun",     // 9
    "Invalid TSS",                     // 10
    "Segment Not Present",             // 11
    "Stack-Segment Fault",             // 12
    "General Protection Fault",        // 13
    "Page Fault",                      // 14
    "Reserved",                        // 15
    "x87 Floating-Point Exception",    // 16
    "Alignment Check",                 // 17
    "Machine Check",                   // 18
    "SIMD Floating-Point Exception",   // 19
    "Virtualization Exception",        // 20
    "Control Protection Exception",    // 21
};

// -----------------------------------------------------------------------------
//  IDT ENTRY CONSTRUCTION
// -----------------------------------------------------------------------------

/// Populate a single Interrupt Descriptor Table entry.
///
/// The supplied 64-bit handler address is split into the individual
/// fields required by the x86_64 interrupt-gate descriptor format.
fn setIDTEntry(index: u8, handler: u64, selector: u16, flags: u8, ist: u8) void {
    idt[index] = IDTEntry{
        .offset_low  = @truncate(handler & 0xFFFF),
        .selector    = selector,
        .ist         = ist,
        .flags       = flags,
        .offset_mid  = @truncate((handler >> 16) & 0xFFFF),
        .offset_high = @truncate((handler >> 32) & 0xFFFFFFFF),
        .reserved    = 0,
    };
}

// -----------------------------------------------------------------------------
//  IDT INITIALISATION
// -----------------------------------------------------------------------------

/// Construct and load the kernel Interrupt Descriptor Table.
///
/// Installs handlers for the most common processor exceptions and
/// then activates the completed table using the lidt instruction.
pub fn init() void {
    const cs_selector: u16 = 0x08; // Kernel code segment selector
    const flags: u8 = 0x8E;        // Present, Ring 0, interrupt gate

    // Register exception handlers for selected CPU fault vectors.
    setIDTEntry(0,  @intFromPtr(&exception0_asm),  cs_selector, flags, 0);
    setIDTEntry(1,  @intFromPtr(&exception1_asm),  cs_selector, flags, 0);
    setIDTEntry(2,  @intFromPtr(&exception2_asm),  cs_selector, flags, 0);
    setIDTEntry(3,  @intFromPtr(&exception3_asm),  cs_selector, flags, 0);
    setIDTEntry(4,  @intFromPtr(&exception4_asm),  cs_selector, flags, 0);
    setIDTEntry(5,  @intFromPtr(&exception5_asm),  cs_selector, flags, 0);
    setIDTEntry(6,  @intFromPtr(&exception6_asm),  cs_selector, flags, 0);
    setIDTEntry(7,  @intFromPtr(&exception7_asm),  cs_selector, flags, 0);
    setIDTEntry(8,  @intFromPtr(&exception8_asm),  cs_selector, flags, 0);
    setIDTEntry(13, @intFromPtr(&exception13_asm), cs_selector, flags, 0);
    setIDTEntry(14, @intFromPtr(&exception14_asm), cs_selector, flags, 0);

    const idtr = IDTR{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base  = @intFromPtr(&idt),
    };

    load_idt(&idtr);
}

// -----------------------------------------------------------------------------
//  FATAL EXCEPTION HANDLING
// -----------------------------------------------------------------------------

/// Display exception information and permanently halt execution.
///
/// Called after the assembly exception stubs have converted CPU-
/// specific exception state into a common (vector, error_code) form.
fn exceptionHandler(num: u64, error_code: u64) noreturn {
    vga.clearScreen(15, 4);

    var buf: [16]u8 = undefined;

    vga.writeStringAt(12, 0, "Exception #", 0x0F, 0x04);
    vga.writeStringAt(12, 11, conv.toHex(u64, num, &buf), 0x0F, 0x04);

    if (num < exception_names.len) {
        vga.writeStringAt(13, 0, exception_names[num], 0x0F, 0x04);
    }

    vga.writeStringAt(15, 0, "Error code: ", 0x0F, 0x04);
    vga.writeStringAt(15, 12, conv.toHex(u64, error_code, &buf), 0x0F, 0x04);

    while (true) {
        asm volatile ("cli; hlt");
    }
}

// -----------------------------------------------------------------------------
//  ASSEMBLY EXCEPTION ENTRY POINTS
// -----------------------------------------------------------------------------

/// Low-level assembly stubs.
///
/// These routines save processor state, normalise exception stack
/// layouts, and transfer control into Zig exception handling code.
extern fn exception0_asm()  void;
extern fn exception1_asm()  void;
extern fn exception2_asm()  void;
extern fn exception3_asm()  void;
extern fn exception4_asm()  void;
extern fn exception5_asm()  void;
extern fn exception6_asm()  void;
extern fn exception7_asm()  void;
extern fn exception8_asm()  void;
extern fn exception13_asm() void;
extern fn exception14_asm() void;

// -----------------------------------------------------------------------------
//  ASM → ZIG EXCEPTION BRIDGE
// -----------------------------------------------------------------------------

/// Entry point invoked by assembly exception handlers.
///
/// The stack pointer references a small structure constructed by the
/// assembly stubs containing the exception vector followed by the
/// associated error code.
pub export fn exceptionHandlerWrapper(stack_ptr: u64) noreturn {
    const num_ptr = @as(*const u64, @ptrFromInt(stack_ptr + 0));
    const err_ptr = @as(*const u64, @ptrFromInt(stack_ptr + 8));

    exceptionHandler(num_ptr.*, err_ptr.*);
}

// -----------------------------------------------------------------------------
//  DYNAMIC GATE REGISTRATION
// -----------------------------------------------------------------------------

/// Install a standard interrupt gate using the default IST entry.
pub fn setGate(vector: u8, handler_addr: u64) void {
    setGateIst(vector, handler_addr, 0);
}

/// Install an interrupt gate with an explicitly specified Interrupt
/// Stack Table entry.
pub fn setGateIst(vector: u8, handler_addr: u64, ist: u8) void {
    const cs_selector: u16 = 0x18;
    const flags: u8 = 0x8E;

    setIDTEntry(vector, handler_addr, cs_selector, flags, ist);
}

/// Register a handler for a remapped hardware IRQ.
///
/// IRQ n is mapped to interrupt vector 32 + n.
pub fn setIrqHandler(irq: u8, handler: *const void) void {
    const vector: u8 = 32 + irq;
    setGate(vector, handler);
}
