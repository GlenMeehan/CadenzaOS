// src/kernel/kernel.zig

const std = @import("std");
const vga = @import("vga.zig");
const e820 = @import("E820.zig");
const conv = @import("convert.zig");
const db = @import("debug.zig");
const bi = @import("boot_info.zig");
const tests = @import("tests.zig");
const fa = @import("frame_allocator.zig");
const e820_test = @import("e820_test.zig");
const E820Store = @import("E820Store.zig");
const bm = @import("bitmap.zig");
const page_alloc_mod = @import("page_allocator.zig");

pub const STACK_SIZE = 0x4000;        // 16 KiB stack
pub const PAGE_TABLE_BYTES = 64 * 1024; // 64 KiB reserved for page tables

// Early static heap used with FixedBufferAllocator (bootstrap heap)
var heap_buffer: [4 * 1024 * 1024]u8 align(4096) = undefined;

/// Kernel panic handler.
/// Clears the screen, prints a panic banner, message, and optional return address,
/// then halts the CPU forever.
pub fn panic(
    msg: []const u8,
    trace: ?*anyopaque,
    return_address: ?usize,
) noreturn {
    _ = trace;

    // Clear screen to red background
    vga.clearScreen(0x4, 0x0); // bg red, fg black

    // Banner
    vga.writeStringAt(0, 0, "KERNEL PANIC", 15, 4);

    // Message
    vga.writeStringAt(2, 0, "Message: ", 14, 4);
    vga.writeStringAt(2, 9, msg, 15, 4);

    // Return address (if any)
    vga.writeStringAt(4, 0, "Return address: ", 14, 4);
    if (return_address) |ra| {
        var buf: [18]u8 = undefined; // "0x" + 16 hex digits
        const hex = conv.toHex(usize, ra, buf[0..]);
        vga.writeStringAt(4, 17, hex, 15, 4);
    } else {
        vga.writeStringAt(4, 17, "(none)", 8, 4);
    }

    // Halt forever
    while (true) {
        asm volatile ("cli; hlt");
    }
}

/// Bootloader entry point.
/// Transfers control to kmain and never returns.
export fn kernel_entry() void {
    kmain();
    unreachable;
}

/// Main kernel entry point.
/// Sets up memory info, basic heap, frame allocator, IDT, bitmap,
/// and runs a few sanity tests (std allocator + frame allocator stress test).
pub export fn kmain() noreturn {
    // Optional debug pause
    // db.pause();

    const welc_mess = "CadenceOS 64 Bit";
    vga.writeString(welc_mess, 15, 0);

    // 1) Copy E820 entries into kernel-owned memory.
    E820Store.init();

    // 2) Tell E820.zig to use the safe copy.
    e820.setTable(E820Store.getTableAddr(), E820Store.getTableCount());

    // 3) Set up a simple heap allocator from the static buffer.
    var fba = std.heap.FixedBufferAllocator.init(&heap_buffer);
    const allocator = fba.allocator();

    // 4) Initialize frame allocator (backed by safe E820 data).
    fa.FrameAllocator.init();

    // --- Simple hex conversion debug output ---
    const x: u64 = 0x1234ABCDEF112233;
    var buf: [16]u8 = undefined;
    const slice = conv.toHex(u64, x, buf[0..]);

    var len_buf: [8]u8 = undefined;
    vga.writeString(conv.toHex(u32, @intCast(slice.len), &len_buf), 15, 0);
    vga.writeString(slice, 15, 0);

    const y: u32 = 0xBADFACE;
    var buf2: [8]u8 = undefined;
    vga.writeStringAt(3, 0, conv.toHex(u32, y, buf2[0..]), 15, 0);

    // --- Boot info: kernel + stack ranges ---
    const info = bi.get();

    var buf_start: [16]u8 = undefined;
    vga.writeStringAt(11, 0, "Kernel start: ", 15, 0);
    vga.writeStringAt(11, 15, conv.toHex(u64, info.kernel_start, &buf_start), 15, 0);

    var buf_end: [16]u8 = undefined;
    vga.writeStringAt(12, 0, "Kernel end:   ", 15, 0);
    vga.writeStringAt(12, 15, conv.toHex(u64, info.kernel_end, &buf_end), 15, 0);

    var buf_stack: [16]u8 = undefined;
    vga.writeStringAt(13, 0, "Stack top:    ", 15, 0);
    vga.writeStringAt(13, 15, conv.toHex(u64, info.stack_top, &buf_stack), 15, 0);

    // --- Memory dump around 0x7000 (debug) ---
    var row2: u16 = 14;
    var offset: usize = 0;
    while (offset < 0x38) : (offset += 8) {
        var buf_offset: [8]u8 = undefined;
        var buf_bytes: [16]u8 = undefined;

        vga.writeStringAt(row2, 0, conv.toHex(u32, @intCast(offset), &buf_offset), 15, 0);
        vga.writeStringAt(row2, 9, ": ", 15, 0);

        const value = @as(*const u64, @ptrFromInt(0x7000 + offset)).*;
        vga.writeStringAt(row2, 11, conv.toHex(u64, value, &buf_bytes), 15, 0);

        row2 += 1;
    }

    // --- IDT setup ---
    const idt = @import("idt.zig");
    idt.init();
    vga.writeStringAt(21, 0, "IDT initialized", 15, 0);

    // Display boot info again (for IDT debug)
    const idt_info = bi.get();
    var buf_idt: [16]u8 = undefined;

    vga.writeStringAt(22, 0, "Kernel start: ", 15, 0);
    vga.writeStringAt(22, 15, conv.toHex(u64, idt_info.kernel_start, &buf_idt), 15, 0);

    vga.writeStringAt(23, 0, "Kernel end:   ", 15, 0);
    vga.writeStringAt(23, 15, conv.toHex(u64, idt_info.kernel_end, &buf_idt), 15, 0);

    // --- Exception tests (leave commented for now) ---
    // tests.trigger_divide_by_zero();
    // tests.test_breakpoint();
    // tests.test_invalid_opcode();
    // tests.test_gpf();
    // tests.test_page_fault();
    // @panic("TEST");

    // --- Optional allocator tests using bootstrap heap ---
    const ENABLE_TESTS = false;
    if (ENABLE_TESTS) {
        tests.runAllocatorTests(allocator);
    }

    // --- Frame allocator: usable regions from E820 ---
    fa.FrameAllocator.init();
    fa.FrameAllocator.parseUsableMemory();
    const regions = fa.getUsableRegions();

    var idx: usize = 0;
    for (regions) |r| {
        var buf_base: [16]u8 = undefined;
        var buf_len: [16]u8 = undefined;

        vga.writeString("Region ", 15, 0);
        vga.writeString(conv.toHex(u64, idx, &buf_base), 15, 0);

        vga.writeString(": base=", 15, 0);
        vga.writeString(conv.toHex(u64, r.base, &buf_base), 15, 0);

        vga.writeString(" len=", 15, 0);
        vga.writeString(conv.toHex(u64, r.length, &buf_len), 15, 0);

        idx += 1;
    }

    // --- Bitmap initialization and reserved ranges ---
    // Initialize bitmap from usable regions
    bm.init(regions);

    // Mark kernel image as used
    bm.markUsedRange(info.kernel_start, info.kernel_end);

    // Mark stack as used
    bm.markUsedRange(info.stack_top - STACK_SIZE, info.stack_top);

    // Mark E820 table as used
    const e820_start = E820Store.getTableAddr();
    const e820_end = e820_start +
    @as(usize, E820Store.getTableCount()) * @sizeOf(E820Store.E820Entry);
    bm.markUsedRange(e820_start, e820_end);

    // Mark bitmap storage itself as used
    const range = bm.getStorageRange();
    bm.markUsedRange(range.start, range.end);

    // Mark page table memory as used
    bm.markUsedRange(info.page_table_base, info.page_table_base + PAGE_TABLE_BYTES);

    // Debug: show bitmap storage range
    const bmRange = bm.getStorageRange();
    var buf_bm_range: [16]u8 = undefined;
    vga.writeString("Bitmap start: 0x", 15, 0);
    vga.writeString(conv.toHex(u64, bmRange.start, &buf_bm_range), 15, 0);
    vga.writeString("Bitmap end:   0x", 15, 0);
    vga.writeString(conv.toHex(u64, bmRange.end, &buf_bm_range), 15, 0);

    // --- Test: std.ArrayList using custom page allocator ---
    var page_alloc = page_alloc_mod.PageAllocator.init();
    const allocator2 = page_alloc.allocator();

    var list: std.ArrayList(u64) = .empty;
    defer list.deinit(allocator2);

    list.append(allocator2, 0xDEAD) catch {
        vga.writeString("ArrayList failed!", 15, 4);
    };

    if (list.items.len > 0) {
        vga.writeString("Custom allocator works with std!", 15, 0);
    }

    // --- Stress test: frame allocator via bitmap ---
    var addrs: [128]usize = undefined;

    // Allocate 128 frames
    for (&addrs) |*slot| {
        const frame = bm.allocFrame() orelse {
            vga.writeStringAt(20, 0, "OOM during stress test", 15, 4);
            break;
        };
        slot.* = frame;
    }

    // Free them in reverse
    var i: usize = addrs.len;
    while (i > 0) : (i -= 1) {
        bm.freeFrame(addrs[i - 1]);
    }

    // Allocate one frame again and check reuse
    const reused = bm.allocFrame() orelse 0;
    if (reused == addrs[0]) {
        vga.writeString("Allocator reuse OK", 15, 2);
    } else {
        vga.writeString("Allocator not reusing frames!", 15, 4);
    }

    // Halt the CPU forever
    while (true) {
        asm volatile ("hlt");
    }
}
