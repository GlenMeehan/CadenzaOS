// cadenzaprograms/prog1.zig
pub fn panic(msg: []const u8, error_return_trace: ?*anyopaque, ret_addr: ?usize) noreturn {
    _ = msg;
    _ = error_return_trace;
    _ = ret_addr;
    while (true) {}
}

// -----------------------------------------------------------------------------
//  SYSCALL HELPERS
//  Same four syscalls the kernel already implements — just wrapped so _start
//  reads more like normal code instead of repeated inline asm blocks.
// -----------------------------------------------------------------------------

fn getScratchByte(offset: u64) u64 {
    var value: u64 = 0;
    asm volatile (
        \\ int $0x80
        : [ret] "={rax}" (value)
        : [rax] "{rax}" (@as(u64, 2)),
                  [rdi] "{rdi}" (offset)
    );
    return value;
}

fn setScratchByte(offset: u64, value: u64) void {
    asm volatile (
        \\ int $0x80
        :
        : [rax] "{rax}" (@as(u64, 3)),
                  [rdi] "{rdi}" (offset),
                  [rsi] "{rsi}" (value)
    );
}

fn printString(msg: []const u8, colour: u64) void {
    asm volatile (
        \\ int $0x80
        :
        : [rax] "{rax}" (@as(u64, 1)),
                  [rdi] "{rdi}" (@as(u64, @intFromPtr(msg.ptr))),
                  [rsi] "{rsi}" (@as(u64, msg.len)),
                  [rdx] "{rdx}" (colour)
    );
}

fn printChar(char: u64, colour: u64) void {
    asm volatile (
        \\ int $0x80
        :
        : [rax] "{rax}" (@as(u64, 4)),
                  [rdi] "{rdi}" (char),
                  [rsi] "{rsi}" (colour)
    );
}

fn exitTask() noreturn {
    asm volatile (
        \\ int $0x80
        :
        : [rax] "{rax}" (@as(u64, 0))
    );
    while (true) asm volatile ("hlt");
}

fn incrementScratchByte(offset: u64, amount: u64) u64 {
    var new_val: u64 = 0;
    asm volatile (
        \\ int $0x80
        : [ret] "={rax}" (new_val)
        : [rax] "{rax}" (@as(u64, 5)),
                  [rdi] "{rdi}" (offset),
                  [rsi] "{rsi}" (amount)
    );
    return new_val;
}

// -----------------------------------------------------------------------------
//  PROGRAM ENTRY
// -----------------------------------------------------------------------------

const COLOUR: u64 = 0x0B;

// Program header (see binfmt.zig in the kernel). Must stay in sync with it.
comptime {
    asm (
        \\.section .header,"a",@progbits
        \\.long 0x505A4443
        \\.short 1
        \\.short 0
        \\.long _start
        \\.long _image_end
        \\.previous
    );
}

fn cstrLen(s: [*:0]const u8) usize {
    var n: usize = 0;
    while (s[n] != 0) n += 1;
    return n;
}

export fn _start(argc: u64, argv: [*]const [*:0]const u8) callconv(.c) void {
    // Offset 0: this program's own instance number (shared across all
    // running copies of prog1). Single atomic increment, nothing else touches it.
    const instance = incrementScratchByte(0, 1);

    printString("Hello from prog1!\n", COLOUR);
    _ = incrementScratchByte(1, 1);

    printString("This is instance #", COLOUR);
    const digit: u64 = '0' + (instance % 10);
    printChar(digit, COLOUR);
    _ = incrementScratchByte(1, 1);

    printString("Total lines printed so far: ", COLOUR);
    const total = incrementScratchByte(1, 1);
    const total_digit: u64 = '0' + (total % 10);
    printChar(total_digit, COLOUR);

    // Print any command-line arguments (argv[0] is the program name, so start at 1)
    var i: u64 = 1;
    while (i < argc) : (i += 1) {
        printString("\narg: ", COLOUR);
        const a = argv[i];
        printString(a[0..cstrLen(a)], COLOUR);
    }

    exitTask();
}
