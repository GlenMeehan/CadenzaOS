// src/kernel/idt.zig
//
// Interrupt Descriptor Table (IDT) setup and basic exception handling
// for x86_64 long mode.
//
// Responsibilities:
//   • Define IDT entry + IDTR structures
//   • Build a 256-entry IDT
//   • Install exception handlers for common faults
//   • Provide a common Zig-level exception handler
//
// This is an early, simple implementation: no IRQs, no IST, no user mode.

const vga = @import("vga.zig");
const conv = @import("convert.zig");

/// IDT entry structure (16 bytes in x86_64)
const IDTEntry = packed struct {
    /// Handler address bits 0–15
    offset_low: u16,
    /// Code segment selector (e.g. 0x18 for 64-bit kernel CS)
    selector: u16,
    /// Interrupt Stack Table index (0 for now)
    ist: u8,
    /// Present | DPL | gate type (0x8E = present, ring 0, 64-bit interrupt gate)
    flags: u8,
    /// Handler address bits 16–31
    offset_mid: u16,
    /// Handler address bits 32–63
    offset_high: u32,
    /// Must be zero
    reserved: u32 = 0,
};

/// IDT register structure (for lidt)
const IDTR = packed struct {
    limit: u16,
    base: u64,
};

/// The IDT itself (256 entries, aligned to 16 bytes)
var idt: [256]IDTEntry align(16) = [_]IDTEntry{.{
    .offset_low = 0,
    .selector = 0,
    .ist = 0,
    .flags = 0,
    .offset_mid = 0,
    .offset_high = 0,
    .reserved = 0,
}} ** 256;

/// Human-readable exception names for debugging
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

/// Set an IDT entry at `index` to point to `handler`.
fn setIDTEntry(index: u8, handler: u64, selector: u16, flags: u8) void {
    idt[index] = IDTEntry{
        .offset_low = @truncate(handler & 0xFFFF),
        .selector = selector,
        .ist = 0,
        .flags = flags,
        .offset_mid = @truncate((handler >> 16) & 0xFFFF),
        .offset_high = @truncate((handler >> 32) & 0xFFFFFFFF),
        .reserved = 0,
    };
}

/// Initialize and load the IDT.
///
/// Installs handlers for a subset of CPU exceptions and then loads
/// the IDT using lidt.
pub fn init() void {
    const cs_selector: u16 = 0x18; // 64-bit kernel code segment
    const flags: u8 = 0x8E;        // present, ring 0, 64-bit interrupt gate

    // Basic exception handlers
    setIDTEntry(0,  @intFromPtr(&exception0_asm),  cs_selector, flags);
    setIDTEntry(1,  @intFromPtr(&exception1_asm),  cs_selector, flags);
    setIDTEntry(2,  @intFromPtr(&exception2_asm),  cs_selector, flags);
    setIDTEntry(3,  @intFromPtr(&exception3_asm),  cs_selector, flags);
    setIDTEntry(4,  @intFromPtr(&exception4_asm),  cs_selector, flags);
    setIDTEntry(5,  @intFromPtr(&exception5_asm),  cs_selector, flags);
    setIDTEntry(6,  @intFromPtr(&exception6_asm),  cs_selector, flags);
    setIDTEntry(7,  @intFromPtr(&exception7_asm),  cs_selector, flags);
    setIDTEntry(8,  @intFromPtr(&exception8_asm),  cs_selector, flags);
    setIDTEntry(13, @intFromPtr(&exception13_asm), cs_selector, flags);
    setIDTEntry(14, @intFromPtr(&exception14_asm), cs_selector, flags);

    // Build IDTR
    const idtr = IDTR{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };

    // Load IDT
    const idtr_ptr = &idtr;
    asm volatile (
        \\lidt (%[ptr])
    :
    : [ptr] "r" (idtr_ptr),
    );
}

/// Common Zig-level exception handler.
///
/// Called by `exceptionHandlerWrapper` after the assembly stub has
/// decoded the exception number and error code.
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

    // Halt forever
    while (true) {
        asm volatile ("cli; hlt");
    }
}

// ------------------------------------------------------------
// Assembly stubs
// ------------------------------------------------------------
//
// These are emitted at comptime and provide the low-level glue
// between the CPU's interrupt mechanism and the Zig handler.
//
// Each exception stub:
//   • pushes an error code (real or dummy)
//   • pushes the exception number
//   • jumps to exceptionCommonAsm
//
// exceptionCommonAsm:
//   • moves RSP into RDI (first SysV argument)
//   • calls exceptionHandlerWrapper(stack_ptr)
// ------------------------------------------------------------

comptime {
    asm (
        \\.global exception0_asm
        \\exception0_asm:
        \\  push $0          # error code (dummy)
    \\  push $0          # exception number
    \\  jmp exceptionCommonAsm
    \\
    \\.global exception1_asm
    \\exception1_asm:
    \\  push $0
    \\  push $1
    \\  jmp exceptionCommonAsm
    \\
    \\.global exception2_asm
    \\exception2_asm:
    \\  push $0
    \\  push $2
    \\  jmp exceptionCommonAsm
    \\
    \\.global exception3_asm
    \\exception3_asm:
    \\  push $0
    \\  push $3
    \\  jmp exceptionCommonAsm
    \\
    \\.global exception4_asm
    \\exception4_asm:
    \\  push $0
    \\  push $4
    \\  jmp exceptionCommonAsm
    \\
    \\.global exception5_asm
    \\exception5_asm:
    \\  push $0
    \\  push $5
    \\  jmp exceptionCommonAsm
    \\
    \\.global exception6_asm
    \\exception6_asm:
    \\  push $0
    \\  push $6
    \\  jmp exceptionCommonAsm
    \\
    \\.global exception7_asm
    \\exception7_asm:
    \\  push $0
    \\  push $7
    \\  jmp exceptionCommonAsm
    \\
    \\.global exception8_asm
    \\exception8_asm:
    \\  push $8          # double fault has an error code pushed by CPU,
    \\                   # but here we're simplifying; adjust if needed.
    \\  jmp exceptionCommonAsm
    \\
    \\.global exception13_asm
    \\exception13_asm:
    \\  push $13
    \\  jmp exceptionCommonAsm
    \\
    \\.global exception14_asm
    \\exception14_asm:
    \\  push $14
    \\  jmp exceptionCommonAsm
    \\
    \\.global exceptionCommonAsm
    \\exceptionCommonAsm:
    \\  mov %rsp, %rdi   # pass stack pointer as first argument (SysV: rdi)
    \\  call exceptionHandlerWrapper
    \\
    );
}

// External symbols for the assembly stubs
extern fn exception0_asm() void;
extern fn exception1_asm() void;
extern fn exception2_asm() void;
extern fn exception3_asm() void;
extern fn exception4_asm() void;
extern fn exception5_asm() void;
extern fn exception6_asm() void;
extern fn exception7_asm() void;
extern fn exception8_asm() void;
extern fn exception13_asm() void;
extern fn exception14_asm() void;

/// Wrapper called from assembly, interprets the stack and calls the Zig handler.
///
/// Stack layout at entry (top of stack = lowest address):
///   [RSP + 0]  = error code
///   [RSP + 8]  = exception number
///
/// We receive RSP as `stack_ptr` and decode these two values.
export fn exceptionHandlerWrapper(stack_ptr: u64) noreturn {
    const err_ptr = @as(*const u64, @ptrFromInt(stack_ptr + 0));
    const num_ptr = @as(*const u64, @ptrFromInt(stack_ptr + 8));
    exceptionHandler(num_ptr.*, err_ptr.*);
}
