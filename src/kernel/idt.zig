// src/kernel/idt.zig
//
// Interrupt Descriptor Table (IDT) setup for x86_64 long mode.
//
// Responsibilities:
//   • Define IDT entry + IDTR structures
//   • Build a 256‑entry IDT
//   • Install exception handlers for common CPU faults
//   • Provide a Zig‑level exception handler
//
// Notes:
//   • No IST, no user mode, no IRQs here (IRQs handled elsewhere)
//   • Assembly stubs push (num, error_code) in a uniform format

const vga = @import("vga.zig");
const conv = @import("convert.zig");

extern fn load_idt(ptr: *const IDTR) void;

// -----------------------------------------------------------------------------
//  IDT ENTRY STRUCTURES
// -----------------------------------------------------------------------------

const IDTEntry = packed struct {
    offset_low:  u16,
    selector:    u16,
    ist:         u8,
    flags:       u8,
    offset_mid:  u16,
    offset_high: u32,
    reserved:    u32 = 0,
};

const IDTR = packed struct {
    limit: u16,
    base:  u64,
};

// 256‑entry IDT, aligned for CPU requirements
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
//  HUMAN‑READABLE EXCEPTION NAMES
// -----------------------------------------------------------------------------

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
//  IDT ENTRY BUILDER
// -----------------------------------------------------------------------------

fn setIDTEntry(index: u8, handler: u64, selector: u16, flags: u8) void {
    idt[index] = IDTEntry{
        .offset_low  = @truncate(handler & 0xFFFF),
        .selector    = selector,
        .ist         = 0,
        .flags       = flags,
        .offset_mid  = @truncate((handler >> 16) & 0xFFFF),
        .offset_high = @truncate((handler >> 32) & 0xFFFFFFFF),
        .reserved    = 0,
    };
}

// -----------------------------------------------------------------------------
//  PUBLIC INITIALIZATION
// -----------------------------------------------------------------------------

pub fn init() void {
    const cs_selector: u16 = 0x08; // kernel code segment
    const flags: u8 = 0x8E;        // present, ring 0, interrupt gate

    // Install exception handlers
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

    const idtr = IDTR{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base  = @intFromPtr(&idt),
    };

    load_idt(&idtr);
}

// -----------------------------------------------------------------------------
//  ZIG‑LEVEL EXCEPTION HANDLER
// -----------------------------------------------------------------------------

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
//  EXCEPTION STUBS (ASM)
// -----------------------------------------------------------------------------

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
//  WRAPPER — CALLED BY ASM STUBS
// -----------------------------------------------------------------------------

pub export fn exceptionHandlerWrapper(stack_ptr: u64) noreturn {
    const num_ptr = @as(*const u64, @ptrFromInt(stack_ptr + 0));
    const err_ptr = @as(*const u64, @ptrFromInt(stack_ptr + 8));
    exceptionHandler(num_ptr.*, err_ptr.*);
}

// -----------------------------------------------------------------------------
//  PUBLIC GATE SETTERS
// -----------------------------------------------------------------------------

pub fn setGate(vector: u8, handler_addr: u64) void {
    const cs_selector: u16 = 0x18; // kernel code segment (GDT index 3)
    const flags: u8 = 0x8E;        // present, ring 0, interrupt gate
    setIDTEntry(vector, handler_addr, cs_selector, flags);
}

pub fn setIrqHandler(irq: u8, handler: *const void) void {
    const vector: u8 = 32 + irq;
    setGate(vector, handler);
}
