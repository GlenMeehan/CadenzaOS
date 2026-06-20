// src/kernel/kernel.zig
//
// Main kernel entry and early boot sequence for CadenzaOS.
//
// Responsibilities:
//   • Provide memmove for freestanding Zig
//   • Set up early heap (FixedBufferAllocator)
//   • Probe / restore / initialize disk + filesystem
//   • Initialize E820 store, frame allocator, bitmap
//   • Mark reserved ranges (kernel, stack, heap, page tables, RAM disk)
//   • Set up IDT + PIC + mouse, enable interrupts
//   • Mount CodaFS (RAM-backed) and launch shell

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
const idt = @import("idt.zig");
const io = @import("port_io.zig");
const pic = @import("pic.zig");
const interrupts = @import("irupts.zig");
const mouse = @import("drivers/mouse.zig");
const keyboard = @import("inputs/keyboard.zig");
const shell = @import("shell.zig");
pub const term = @import("terminal.zig");
const conf = @import("config.zig");
const AtaBD = @import("fs/ata_block_device.zig").AtaBlockDevice;
const coda_fs = @import("fs/coda_fs.zig");
const CodaFs = coda_fs.CodaFs;
const bd = @import("fs/block_device.zig").BlockDevice;
const ata = @import("drivers/ata.zig");
const scheduler = @import("scheduler.zig");
const task = @import("task.zig");
const bin_loader = @import("fs/binary_loader.zig");

pub const STACK_SIZE = 0x40000;         // 16 KiB stack
pub const PAGE_TABLE_BYTES = 64 * 1024; // 64 KiB reserved for page tables

extern fn irq0_stub() void;
extern fn irq1_stub() void;
extern fn irq12_stub() void;

var ticks: u64 = 0;

// -----------------------------------------------------------------------------
//  EARLY HEAP / RAM DISK
// -----------------------------------------------------------------------------

// Early static heap used with FixedBufferAllocator (bootstrap heap)
var heap_buffer: [4  * 1024 * 1024]u8 align(4096) linksection(".bss") = undefined;

// Global FixedBufferAllocator — lifetime = whole kernel
var fba = std.heap.FixedBufferAllocator.init(&heap_buffer);
pub var allocator: std.mem.Allocator = undefined;

// RAM Disk virtual mapping
pub const RAMDISK_VIRT_ADDR: usize = 0xFFFFFF8001000000;
pub const RAMDISK_SIZE: usize = 4 * 1024 * 1024;

// Anchor the buffer as a pointer to the array at that fixed virtual address
pub const fs_ramdisk_buf: *[RAMDISK_SIZE]u8 = @ptrFromInt(RAMDISK_VIRT_ADDR);

// Global filesystem instance (RAM-backed CodaFS)
pub var fs_global: CodaFs align(4096) linksection(".bss") = undefined;

// -----------------------------------------------------------------------------
// THE PERMANENT KERNEL STACK
// -----------------------------------------------------------------------------
// A dedicated 16KB stack array sitting safely in the permanent .bss section
var kmain_stack: [16384]u8 align(16) linksection(".bss") = undefined;

// -----------------------------------------------------------------------------
//  STATIC SHELL STACK - This buffer is statically allocated outside of kmain's stack frame
// -----------------------------------------------------------------------------
var shell_stack_buf: [16384]u8 align(16) = undefined;


// -----------------------------------------------------------------------------
//  FREESTANDING SUPPORT: memmove
// -----------------------------------------------------------------------------

pub export fn memmove(dest: ?[*]u8, src: ?[*]const u8, n: usize) ?[*]u8 {
    const d = dest orelse return dest;
    const s = src orelse return dest;

    if (@intFromPtr(d) < @intFromPtr(s)) {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            d[i] = s[i];
        }
    } else {
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            d[i] = s[i];
        }
    }
    return dest;
}


// -----------------------------------------------------------------------------
//  PANIC HANDLER (KERNEL-LOCAL)
// -----------------------------------------------------------------------------

/// Kernel panic handler.
/// Clears the screen, prints a panic banner, message, and optional return address,
/// then halts the CPU forever.
pub fn panic(
    msg: []const u8,
    trace: ?*anyopaque,
    return_address: ?usize,
) noreturn {
    _ = trace;

    vga.clearScreen(0x4, 0x0); // bg red, fg black

    vga.writeStringAt(0, 0, "KERNEL PANIC", 15, 4);

    vga.writeStringAt(2, 0, "Message: ", 14, 4);
    vga.writeStringAt(2, 9, msg, 15, 4);

    vga.writeStringAt(4, 0, "Return address: ", 14, 4);
    if (return_address) |ra| {
        var buf: [18]u8 = undefined; // "0x" + 16 hex digits
        const hex = conv.toHex(usize, ra, buf[0..]);
        vga.writeStringAt(4, 17, hex, 15, 4);
    } else {
        vga.writeStringAt(4, 17, "(none)", 8, 4);
    }

    while (true) {
        asm volatile ("cli; hlt");
    }
}

/// This function serves as the entry point for the managed Shell task.
/// It wraps the true shell runner with the global kernel state variables.
fn shellTaskWrapper() callconv(.c) void {
    // Force interrupts to be enabled inside the task context
    asm volatile ("sti");

    // Launch your interactive loop
    shell.run(&fs_global, allocator);

    // Safety fallback if shell exits
    while (true) {
        asm volatile ("hlt");
    }
}

// Ensure IRQ handlers are retained
comptime {
    _ = interrupts.irq0_handler;
    _ = interrupts.irq1_handler;
    _ = interrupts.irq12_handler;
}

pub const std_options: std.Options = .{
    .page_size_min = 4096,
    .page_size_max = 4096,
};

// -----------------------------------------------------------------------------
//  ENTRY POINTS
// -----------------------------------------------------------------------------

/// Bootloader entry point.
/// Transfers control to kmain and never returns.
export fn kernel_entry() void {
    kmain();
    unreachable;
}



/// Main kernel entry point.
pub export fn kmain() noreturn {
    // 1. Calculate the top of our new stack array
    const new_sp = @intFromPtr(&kmain_stack) + kmain_stack.len;

    // 2. Inline assembly compliant with modern Zig syntax
    asm volatile (
        \\ movq %[stack], %%rsp
        :
        : [stack] "r" (new_sp),
    );


    // -------------------------------------------------------------------------
    //  BSS / EARLY CLEAR
    // -------------------------------------------------------------------------
    @memset(&heap_buffer, 0);
    @memset(fs_ramdisk_buf, 0);

    // IDT must be initialized early
    idt.init();

    vga.writeString("Probing Disk...\n", 15, 0);

    // -------------------------------------------------------------------------
    //  DISK / FILESYSTEM RESTORE OR INIT
    // -------------------------------------------------------------------------
    var fs_exists: bool = false;
    const partition_start = conf.PARTITION_START_LBA;

    if (ata.AtaDevice.checkFileSystem(partition_start)) {
        fs_exists = true;
        vga.writeString("STATUS: System Partition Found!\n", 10, 0);

        vga.writeString("RESTORE: Populating RAM from Disk...\n", 11, 0);
        ata.AtaDevice.readBlocks(null, partition_start, fs_ramdisk_buf[0..]) catch |err| {
            vga.writeString("ERROR: Restoration failed! Type: ", 12, 0);
            vga.writeString(@errorName(err), 12, 0);
        };

        const sb = @as(*coda_fs.Superblock, @ptrCast(@alignCast(&fs_ramdisk_buf[0])));

        if ((sb.flags & coda_fs.FLAG_DIRTY) != 0) {
            vga.writeString("WARNING: Last shutdown was UNCLEAN!\n", 14, 0);
        } else {
            vga.writeString("STATUS: Filesystem is healthy.\n", 10, 0);
        }

        sb.flags |= coda_fs.FLAG_DIRTY;

        ata.AtaDevice.writeBlocks(null, partition_start, fs_ramdisk_buf[0..conf.BLOCK_SIZE]) catch {
            vga.writeString("ERROR: Could not mark disk as DIRTY!\n", 12, 0);
        };

        vga.writeString("STATUS: Filesystem Ready.\n", 10, 0);
    } else {
        fs_exists = false;
        vga.writeString("STATUS: Disk is Blank.\n", 14, 0);

        vga.writeString("Initializing MBR...\n", 15, 0);
        ata.initializePartitionTable(partition_start, 16384);

        vga.writeString("Formatting Partition...\n", 15, 0);
        ata.formatMyFileSystem(partition_start);

        ata.AtaDevice.readBlocks(null, partition_start, fs_ramdisk_buf[0..conf.BLOCK_SIZE]) catch {};

        vga.writeString("Done. Please close QEMU and run ./build.sh run\n", 11, 0);
    }

    vga.step(0);

    // -------------------------------------------------------------------------
    //  E820 / FRAME ALLOCATOR / REGIONS
    // -------------------------------------------------------------------------
    const welc_mess = "CadenzaOS 64 Bit";
    vga.writeString(welc_mess, 15, 0);

    // 1) Copy E820 entries into kernel-owned memory.
    E820Store.init();
    vga.step(1);

    // 2) Tell E820.zig to use the safe copy.
    e820.setTable(E820Store.getTableAddr(), E820Store.getTableCount());
    vga.step(2);

    // 3) Use the global FixedBufferAllocator as the kernel heap
    allocator = fba.allocator();

    // 4) Initialize frame allocator (backed by safe E820 data).
    fa.FrameAllocator.init();
    fa.FrameAllocator.parseUsableMemory();
    const regions = fa.getUsableRegions();
    vga.step(3);

    // -------------------------------------------------------------------------
    //  DEBUG: HEX / BOOT INFO / MEMORY DUMP
    // -------------------------------------------------------------------------
    const x: u64 = 0x1234ABCDEF112233;
    var buf: [16]u8 = undefined;
    const slice = conv.toHex(u64, x, buf[0..]);

    var len_buf: [8]u8 = undefined;
    vga.writeString(conv.toHex(u32, @intCast(slice.len), &len_buf), 15, 0);
    vga.writeString(slice, 15, 0);

    const y: u32 = 0xBADFACE;
    var buf2: [8]u8 = undefined;
    vga.writeStringAt(3, 0, conv.toHex(u32, y, buf2[0..]), 15, 0);

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

    // -------------------------------------------------------------------------
    //  IDT / PIC / MOUSE / INTERRUPTS
    // -------------------------------------------------------------------------
    idt.setGate(32, @intFromPtr(&irq0_stub));
    idt.setGate(33, @intFromPtr(&irq1_stub));
    idt.setGate(44, @intFromPtr(&irq12_stub));

    pic.remap(32, 40);
    pic.unmaskIrq(@as(u8, 0));  // timer
    pic.unmaskIrq(@as(u8, 1));  // keyboard
    pic.unmaskIrq(@as(u8, 2));  // cascade to slave PIC
    pic.unmaskIrq(@as(u8, 12)); // mouse

    mouse.initMouse();

    interrupts.init_pit(100); // 100Hz = 100 ticks per second

    asm volatile ("sti");

    vga.step(4);
    vga.writeStringAt(21, 0, "IDT + PIC remapped", 15, 0);

    const idt_info = bi.get();
    var buf_idt: [16]u8 = undefined;

    vga.writeStringAt(22, 0, "Kernel start: ", 15, 0);
    vga.writeStringAt(22, 15, conv.toHex(u64, idt_info.kernel_start, &buf_idt), 15, 0);

    vga.writeStringAt(23, 0, "Kernel end:   ", 15, 0);
    vga.writeStringAt(23, 15, conv.toHex(u64, idt_info.kernel_end, &buf_idt), 15, 0);

    // -------------------------------------------------------------------------
    //  FRAME ALLOCATOR REGIONS DEBUG
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    //  BITMAP INIT + RESERVED RANGES
    // -------------------------------------------------------------------------
    bm.init(regions);
    vga.step(5);

    // Kernel image
    bm.markUsedRange(info.kernel_start, info.kernel_end);

    // Stack
    bm.markUsedRange(info.stack_top - STACK_SIZE, info.stack_top);
    vga.step(6);

    // Heap
    const mem_mod = @import("memory.zig");
    const heap_virt = @intFromPtr(&heap_buffer[0]);
    const heap_phys = mem_mod.virtToPhys(heap_virt);
    bm.markUsedRange(heap_phys, heap_phys + heap_buffer.len);

    // E820 table
    const e820_start = E820Store.getTableAddr();
    const e820_end = e820_start +
    @as(usize, E820Store.getTableCount()) * @sizeOf(E820Store.E820Entry);
    bm.markUsedRange(e820_start, e820_end);

    // Bitmap storage
    const range = bm.getStorageRange();
    bm.markUsedRange(range.start, range.end);

    // Page tables
    bm.markUsedRange(info.page_table_base, info.page_table_base + PAGE_TABLE_BYTES);

    // RAM disk buffer
    const ramdisk_virt = @intFromPtr(&fs_ramdisk_buf[0]);
    const ramdisk_phys = mem_mod.virtToPhys(ramdisk_virt);
    bm.markUsedRange(ramdisk_phys, ramdisk_phys + fs_ramdisk_buf.len);

    // Debug: bitmap storage range
    const bmRange = bm.getStorageRange();
    var buf_bm_range: [16]u8 = undefined;
    vga.writeString("Bitmap start: 0x", 15, 0);
    vga.writeString(conv.toHex(u64, bmRange.start, &buf_bm_range), 15, 0);
    vga.writeString("Bitmap end:   0x", 15, 0);
    vga.writeString(conv.toHex(u64, bmRange.end, &buf_bm_range), 15, 0);

    // -------------------------------------------------------------------------
    //  FRAME ALLOCATOR STRESS TEST
    // -------------------------------------------------------------------------
    var addrs: [128]usize = undefined;

    for (&addrs) |*slot| {
        const frame = bm.allocFrame() orelse {
            vga.writeStringAt(20, 0, "OOM during stress test", 15, 4);
            break;
        };
        slot.* = frame;
    }

    var i: usize = addrs.len;
    while (i > 0) : (i -= 1) {
        bm.freeFrame(addrs[i - 1]);
    }

    const reused = bm.allocFrame() orelse 0;
    if (reused == addrs[0]) {
        vga.writeString("Allocator reuse OK", 15, 2);
    } else {
        vga.writeString("Allocator not reusing frames!", 15, 4);
    }

    var buf_status: [16]u8 = undefined;
    const status = io.inb(0x64); // keyboard controller status port
    vga.writeString("KBC status: ", 15, 0);
    vga.writeString(conv.toHex(u64, status, &buf_status), 15, 0);

    const FORCE_PANIC = false;
    if (FORCE_PANIC) {
        @panic("TEST");
    }

    asm volatile ("sti");
    vga.clearScreen(15, 0);

    // =========================================================================
    // TASK MANAGER INITIALIZATION
    // =========================================================================
    scheduler.manager = scheduler.Scheduler.init(allocator);

    if (conf.USE_SCHEDULER_SHELL) {
        scheduler.manager.registerCurrentThreadAsTask(0, 0);
        scheduler.manager.current_task_idx = 0;
    }

    // =========================================================================
    // PERMANENT STORAGE & FILE SYSTEM BRING UP
    // =========================================================================
    var ram_disk = @import("fs/ramdisk.zig").RamDisk.init(fs_ramdisk_buf[0..], 512);
    var dev = ram_disk.asBlockDevice();

    if (!fs_exists) {
        CodaFs.mkfs(allocator, &dev) catch |err| {
            @panic(@errorName(err));
        };
    }

    const fs = CodaFs.mount(allocator, &dev) catch |err| {
        vga.writeString("Mount failed: ", 12, 4);
        @panic(@errorName(err));
    };

    fs_global.device = fs.device;
    fs_global.superblock = fs.superblock;
    fs_global.space_manager = fs.space_manager;
    fs_global.root_dir = fs.root_dir;

    // Run the embedded application installation staging pipeline
    bin_loader.installEmbeddedApps(allocator, &fs_global) catch |err| {
        vga.writeString("Application injection failure: ", 12, 5);
        @panic(@errorName(err));
    };

    // ... Right after bin_loader.installEmbeddedApps(allocator, &fs_global) ...

    //vga.writeString("\n🔍 Verifying prog1.bin read...", 10, 6);

    // 1. Allocate a buffer large enough to hold the file (4236 bytes)
    const test_buf = allocator.alloc(u8, 4236) catch |err| {
        @panic(@errorName(err));
    };
    defer allocator.free(test_buf);

    // 2. Call our new readFile function
    const bytes_read = fs_global.readFile(allocator, "/prog1", test_buf) catch |err| {
        vga.writeString("\n❌ Read failed: ", 12, 7);
        vga.writeString(@errorName(err), 12, 7);
        @panic(@errorName(err));
    };

    // Silence the unused variable error for bytes_read
    _ = bytes_read;

    // 3. Print a success indicator to the screen
    //vga.writeString("\n✅ Read successful!", 10, 8);

    // Silence the unused capture by using a blank identifier in the loop
    for (test_buf[0..4]) |_| {
        // We can leave this empty now, Zig is happy with the underscore
    }

    // =========================================================================
    //  SHELL STARTUP WITH DEDICATED STACK SWAP
    // =========================================================================
    if (conf.USE_SCHEDULER_SHELL) {
        // 1. Calculate the absolute top of our private shell stack buffer
        const stack_top = @intFromPtr(&shell_stack_buf) + shell_stack_buf.len;

        // 2. HARDWARE SWAP: Force the CPU to leave the kernel boot stack
        // and instantly start using our private shell stack buffer.
        asm volatile (
            \\ mov %[top], %%rsp
            \\ xor %%rbp, %%rbp
            :
            : [top] "r" (stack_top)
            : .{} // Passes an empty compile-time struct literal
        );

        // 3. Now that the CPU is physically isolated on its own stack,
        // we register this exact execution state as Task 0.
        scheduler.manager.registerCurrentThreadAsTask(0, 0);
        scheduler.manager.current_task_idx = 0;

        // 4. Safely enable the preemption engine
        scheduler.manager.yield_enabled = true;

        // Unmask the hardware timer interrupts
        asm volatile ("sti");

        // 5. Run the shell natively. Every variable it allocates now lands
        // cleanly inside 'shell_stack_buf', completely leaving the kernel stack behind.
        shell.run(&fs_global, allocator);

        while (true) { asm volatile ("hlt"); }
    } else {
        scheduler.manager.yield_enabled = false;
        shell.run(&fs_global, allocator);
    }

    // Optional allocator tests (kept as-is)
    const ENABLE_TESTS = false;
    if (ENABLE_TESTS) {
        tests.runAllocatorTests(allocator);
        vga.step(7);
    }

    while (true) {
        asm volatile ("hlt");
    }
}
