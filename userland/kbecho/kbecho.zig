// userland/kbecho/kbecho.zig
//
// Keyboard read test for the read (6) and yield (7) syscalls.
//
// Reads typed characters until Enter, echoing them as they arrive, then
// prints the finished line and exits. Used by tests/smoke.sh.
//
// Programs have no .bss (the linker script forbids it), so every buffer
// here lives on the stack.

const LINE_MAX = 64;

pub fn panic(msg: []const u8, error_return_trace: ?*anyopaque, ret_addr: ?usize) noreturn {
    _ = msg;
    _ = error_return_trace;
    _ = ret_addr;
    while (true) {}
}

// -----------------------------------------------------------------------------
//  SYSCALL HELPERS
// -----------------------------------------------------------------------------

const COLOUR: u64 = 0x0B;

/// Syscall 1: print a string.
fn printString(msg: []const u8, colour: u64) void {
    asm volatile (
        \\ int $0x80
        :
        : [rax] "{rax}" (@as(u64, 1)),
                  [rdi] "{rdi}" (@as(u64, @intFromPtr(msg.ptr))),
                  [rsi] "{rsi}" (@as(u64, msg.len)),
                  [rdx] "{rdx}" (colour),
                  : .{ .memory = true });
}

/// Syscall 6: non-blocking read. Returns the number of bytes stored in
/// buf (0 if nothing is waiting) or all ones if the buffer was rejected.
fn readInput(buf: []u8) u64 {
    var count: u64 = 0;
    asm volatile (
        \\ int $0x80
        : [ret] "={rax}" (count),
                  : [rax] "{rax}" (@as(u64, 6)),
                  [rdi] "{rdi}" (@as(u64, @intFromPtr(buf.ptr))),
                  [rsi] "{rsi}" (@as(u64, buf.len)),
                  : .{ .memory = true });
    return count;
}

/// Syscall 7: give up the rest of this time slice.
fn yieldCpu() void {
    var ret: u64 = 0;
    asm volatile (
        \\ int $0x80
        : [ret] "={rax}" (ret),
                  : [rax] "{rax}" (@as(u64, 7)),
                  : .{ .memory = true });
}

/// Syscall 0: exit.
fn exitTask() noreturn {
    asm volatile (
        \\ int $0x80
        :
        : [rax] "{rax}" (@as(u64, 0)),
    );
    while (true) asm volatile ("hlt");
}

// -----------------------------------------------------------------------------
//  PROGRAM ENTRY
// -----------------------------------------------------------------------------

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

export fn _start(argc: u64, argv: [*]const [*:0]const u8) callconv(.c) void {
    _ = argc;
    _ = argv;

    printString("kbecho ready\n", COLOUR);

    var line: [LINE_MAX]u8 = undefined;
    var len: usize = 0;
    var ch: [1]u8 = undefined;

    while (true) {
        const n = readInput(ch[0..1]);

        // Nothing waiting: let other tasks run, then look again.
        if (n == 0) {
            yieldCpu();
            continue;
        }

        // The kernel rejected the buffer.
        if (n != 1) {
            printString("kbecho: read failed\n", COLOUR);
            exitTask();
        }

        const c = ch[0];

        // Enter finishes the line.
        if (c == '\n' or c == '\r') break;

        // Backspace removes the last character.
        if (c == 0x08) {
            if (len > 0) len -= 1;
            continue;
        }

        // Printable characters are stored and echoed.
        if (c >= 32 and c < 127 and len < LINE_MAX) {
            line[len] = c;
            len += 1;
            printString(ch[0..1], COLOUR);
        }
    }

    printString("\ngot: ", COLOUR);
    if (len > 0) printString(line[0..len], COLOUR);
    printString("\n", COLOUR);

    exitTask();
}
