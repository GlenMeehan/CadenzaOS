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
//const libc = @import("libc.zig");

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


pub const STACK_SIZE = 0x40000;        // 16 KiB stack
pub const PAGE_TABLE_BYTES = 64 * 1024; // 64 KiB reserved for page tables
extern fn irq0_stub() void;
extern fn irq1_stub() void;
extern fn irq12_stub() void;
var ticks: u64 = 0;

// Early static heap used with FixedBufferAllocator (bootstrap heap)
var heap_buffer: [1024 * 1024]u8 align(4096) linksection(".bss") = undefined;

// Global FixedBufferAllocator — lifetime = whole kernel
var fba = std.heap.FixedBufferAllocator.init(&heap_buffer);

//RAM Disk Buffer
var fs_ramdisk_buf: [4 * 1024 * 1024]u8 align(4096) linksection(".bss") = undefined;

var fs_global: CodaFs align(4096) linksection(".bss") = undefined;


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

comptime {
    _ = interrupts.irq0_handler;
    _ = interrupts.irq1_handler;
    _ = interrupts.irq12_handler;
}

pub const std_options: std.Options = .{
    .page_size_min = 4096,
    .page_size_max = 4096,
};


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
    // Clear the BSS as we discussed

    @memset(&heap_buffer, 0);
    @memset(&fs_ramdisk_buf, 0);



    // Ensure IDT is init'd so the compiler doesn't prune it
    idt.init();
    vga.writeString("Probing Disk...\n", 15, 0);


    // 1. Identify the partition
    var fs_exists: bool = false;
    const partition_start = 2048;

    if (ata.AtaDevice.checkFileSystem(partition_start)) {
        fs_exists = true;
        vga.writeString("STATUS: System Partition Found!\n", 10, 0);
        // 2. THE GATHER: Load the entire disk partition into your RAM buffer
        // This restores your files, inodes, and superblock from the last session
        vga.writeString("RESTORE: Populating RAM from Disk...\n", 11, 0);
        ata.AtaDevice.readBlocks(null, partition_start, fs_ramdisk_buf[0..]) catch |err| {
            vga.writeString("ERROR: Restoration failed! Type: ", 12, 0);
            vga.writeString(@errorName(err), 12, 0);
            // Optional: while(true) {} // Halt here if you don't want to boot with a broken FS
        };

        // 3. DIRTY BIT LOGIC
        // We cast the start of our main RAM buffer as the Superblock
        const sb = @as(*coda_fs.Superblock, @ptrCast(@alignCast(&fs_ramdisk_buf[0])));


        // Check the FLAG_DIRTY using your defined constant
        if ((sb.flags & coda_fs.FLAG_DIRTY) != 0) {
            vga.writeString("WARNING: Last shutdown was UNCLEAN!\n", 14, 0);
        } else {
            vga.writeString("STATUS: Filesystem is healthy.\n", 10, 0);
        }

        // 4. LOCK: Mark the filesystem as dirty in RAM
        sb.flags |= coda_fs.FLAG_DIRTY;

        // 5. SYNC: Write just the Superblock sector back to disk to "lock" it
        // We only write 512 bytes here for speed; the rest is already in RAM
        ata.AtaDevice.writeBlocks(null, partition_start, fs_ramdisk_buf[0..512]) catch {
            vga.writeString("ERROR: Could not mark disk as DIRTY!\n", 12, 0);
        };

        vga.writeString("STATUS: Filesystem Ready.\n", 10, 0);

    } else {
        fs_exists = false;
        vga.writeString("STATUS: Disk is Blank.\n", 14, 0);

        vga.writeString("Initializing MBR...\n", 15, 0);
        ata.initializePartitionTable(partition_start, 16384);

        vga.writeString("Formatting Partition...\n", 15, 0);
        // This writes a clean Superblock (flags = 0) to the disk
        ata.formatMyFileSystem(partition_start);

        // Now we read that fresh Superblock into our RAM buffer
        // so the FS initialization sees the Magic Number we just wrote
        ata.AtaDevice.readBlocks(null, partition_start, fs_ramdisk_buf[0..512]) catch {};

        vga.writeString("Done. Please close QEMU and run ./build.sh run\n", 11, 0);
    }


    //io.pause(); // The code stops here!

    vga.step(0);

    // Optional debug pause
    // db.pause();

    const welc_mess = "CadenzaOS 64 Bit";
    vga.writeString(welc_mess, 15, 0);
    // 1) Copy E820 entries into kernel-owned memory.
    E820Store.init();
    vga.step(1);

    // 2) Tell E820.zig to use the safe copy.
    e820.setTable(E820Store.getTableAddr(), E820Store.getTableCount());
    vga.step(2);

    // 3) Use the global FixedBufferAllocator as the kernel heap
    const allocator = fba.allocator();

    // 4) Initialize frame allocator (backed by safe E820 data).
    fa.FrameAllocator.init();
    fa.FrameAllocator.parseUsableMemory();
    const regions = fa.getUsableRegions();
    vga.step(3);

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
    idt.setGate(32, @intFromPtr(&irq0_stub));
    idt.setGate(33, @intFromPtr(&irq1_stub));
    idt.setGate(44, @intFromPtr(&irq12_stub));
    pic.remap(32, 40);
    pic.unmaskIrq(@as(u8, 0)); //timer
    pic.unmaskIrq(@as(u8, 1));//keyborad
    pic.unmaskIrq(@as(u8, 2));  // cascade to slave PIC
    pic.unmaskIrq(@as(u8, 12));//mouse

    mouse.initMouse();   // PS/2 controller + mouse

    asm volatile ("sti");


    vga.step(4);
    vga.writeStringAt(21, 0, "IDT + PIC remapped", 15, 0);
    // Display boot info again (for IDT debug)
    const idt_info = bi.get();
    var buf_idt: [16]u8 = undefined;

    vga.writeStringAt(22, 0, "Kernel start: ", 15, 0);
    vga.writeStringAt(22, 15, conv.toHex(u64, idt_info.kernel_start, &buf_idt), 15, 0);

    vga.writeStringAt(23, 0, "Kernel end:   ", 15, 0);
    vga.writeStringAt(23, 15, conv.toHex(u64, idt_info.kernel_end, &buf_idt), 15, 0);



    // --- Frame allocator: usable regions from E820 ---
    //fa.FrameAllocator.init();
    //fa.FrameAllocator.parseUsableMemory();
    //const regions = fa.getUsableRegions();

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
    vga.step(5);

    // Mark kernel image as used
    bm.markUsedRange(info.kernel_start, info.kernel_end);

    // Mark stack as used
    bm.markUsedRange(info.stack_top - STACK_SIZE, info.stack_top);
    vga.step(6);



    //Mark heap as used
    const mem = @import("memory.zig");
    const heap_virt = @intFromPtr(&heap_buffer[0]);
    const heap_phys = mem.virtToPhys(heap_virt);
    bm.markUsedRange(heap_phys, heap_phys + heap_buffer.len);

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

    // Mark RAM disk buffer as used
    const ramdisk_virt = @intFromPtr(&fs_ramdisk_buf[0]);
    const ramdisk_phys = mem.virtToPhys(ramdisk_virt);
    bm.markUsedRange(ramdisk_phys, ramdisk_phys + fs_ramdisk_buf.len);



    // Debug: show bitmap storage range
    const bmRange = bm.getStorageRange();
    var buf_bm_range: [16]u8 = undefined;
    vga.writeString("Bitmap start: 0x", 15, 0);
    vga.writeString(conv.toHex(u64, bmRange.start, &buf_bm_range), 15, 0);
    vga.writeString("Bitmap end:   0x", 15, 0);
    vga.writeString(conv.toHex(u64, bmRange.end, &buf_bm_range), 15, 0);

    //while (true) asm volatile ("cli; hlt");

    // --- Test: std.ArrayList using custom page allocator ---
    //var page_alloc = page_alloc_mod.PageAllocator.init();
    //const allocatortest = page_alloc.allocator();

    //var list: std.ArrayList(u64) = .empty;
    //defer list.deinit(allocatortest);

    //list.append(allocatortest, 0xDEAD) catch {
        //vga.writeString("ArrayList failed!", 15, 4);
   //};

    //if (list.items.len > 0) {
        //vga.writeString("Custom allocator works with std!", 15, 0);
    //}

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
    var buf_status: [16]u8 = undefined;
    const status = io.inb(0x64); // keyboard controller status port
    vga.writeString("KBC status: ", 15, 0);
    vga.writeString(conv.toHex(u64, status, &buf_status), 15, 0);

    // --- Exception tests (leave commented for now) ---
    // tests.trigger_divide_by_zero();
    // tests.test_breakpoint();
    // tests.test_invalid_opcode();
    // tests.test_gpf();
    // tests.test_page_fault();
    const FORCE_PANIC = false;
    if (FORCE_PANIC) {
        @panic("TEST");
    }

    //vga.clearScreen(0, 0);
    asm volatile ("sti");
    //vga.writeString("Start Typing\n", 15, 0);
    vga.clearScreen(15,0);

    // --- Filesystem bring-up ---

    // 1. ALWAYS initialize the RamDisk first.
    // This points to your 4MB buffer (which was either zeroed or filled from ATA earlier)
    var ram_disk = @import("fs/ramdisk.zig").RamDisk.init(fs_ramdisk_buf[0..], 512);
    var dev = ram_disk.asBlockDevice();

    // 2. Handle the two cases (New vs Existing)
    if (!fs_exists) {
        // CASE A: Blank Disk.
        // We format the RAM Workspace directly.
        vga.writeString("Creating new filesystem in RAM...\n", 15, 0);
        CodaFs.mkfs(allocator, &dev) catch |err| {
            @panic(@errorName(err));
        };
    }

    // 3. Mount the filesystem.
    // Whether we just formatted it or restored it from ATA,
    // the 'truth' is now in the RAM Workspace.
    const fs = CodaFs.mount(allocator, &dev) catch |err| {
        vga.writeString("Mount failed: ", 12, 4);
        @panic(@errorName(err));
    };

    // 4. Update the global pointer for the shell
    fs_global.device = fs.device;
    fs_global.superblock = fs.superblock;
    fs_global.space_manager = fs.space_manager;
    fs_global.root_dir = fs.root_dir;

    vga.writeString("FS Engine Online (RAM-Backed).\n", 10, 0);

    //vga.clearScreen(0, 0);

    // 5. Pass to shell
    shell.run(&fs_global, allocator);

    // --- Optional allocator tests using bootstrap heap ---
    const ENABLE_TESTS = false;
    if (ENABLE_TESTS) {
        tests.runAllocatorTests(allocator);
        vga.step(7);
    }


    // Halt the CPU forever
    while (true) {
        asm volatile ("hlt");
    }
}
