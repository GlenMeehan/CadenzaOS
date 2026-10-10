// src/kernel/kernel.zig
//
// Main kernel entry point and early-boot orchestration for CadenzaOS.
//
// Responsibilities:
//   • Provide freestanding runtime support required by Zig
//   • Initialise the bootstrap heap allocator
//   • Discover and initialise physical memory management
//   • Probe, restore, and mount storage devices and filesystems
//   • Configure interrupt handling and input devices
//   • Set up task scheduling infrastructure
//   • Initialise the RAM-backed CodaFS instance
//   • Launch the initial user-facing shell environment
//
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
const memory = @import("memory.zig");
const boot_info_mod = @import("boot_info.zig");
const serial = @import("drivers/serial.zig");
const fb = @import("framebuffer.zig");
const apic = @import("apic.zig");
const splash = @import("splash.zig");
const tss = @import("tss.zig");

/// Size of the permanent kernel stack.
pub const STACK_SIZE = 0x40000; // 16 KiB

/// Memory reserved for early page-table structures.
pub const PAGE_TABLE_BYTES = 64 * 1024; // 64 KiB

extern fn irq0_stub() void;
extern fn irq1_stub() void;
extern fn irq12_stub() void;

/// Legacy local tick counter.
///
/// Global timer state is maintained by the interrupt subsystem.
var ticks: u64 = 0;

// -----------------------------------------------------------------------------
//  BOOTSTRAP HEAP AND RAM DISK
// -----------------------------------------------------------------------------

/// Early static heap used by the FixedBufferAllocator.
///
/// This allocator provides dynamic memory support before more advanced
/// memory-management facilities are fully available.
var heap_buffer: [10 * 1024 * 1024]u8 align(4096) linksection(".bss") = undefined;

/// Bootstrap allocator with kernel-lifetime storage.
var fba = std.heap.FixedBufferAllocator.init(&heap_buffer);

/// Global allocator interface used during and after early boot.
pub var allocator: std.mem.Allocator = undefined;

// -----------------------------------------------------------------------------
//  RAM DISK CONFIGURATION
// -----------------------------------------------------------------------------

/// Fixed virtual address reserved for the kernel RAM disk.
pub const RAMDISK_VIRT_ADDR: usize = 0xFFFFFF8002000000;

/// RAM disk size in bytes.
pub const RAMDISK_SIZE: usize = 4 * 1024 * 1024;

/// Typed pointer to the RAM disk's virtual memory region.
///
/// The mapping itself is established elsewhere during memory
/// initialisation.
pub const fs_ramdisk_buf: *[RAMDISK_SIZE]u8 = @ptrFromInt(RAMDISK_VIRT_ADDR);

/// Global RAM-backed CodaFS filesystem instance.
pub var fs_global: CodaFs align(4096) linksection(".bss") = undefined;

// -----------------------------------------------------------------------------
//  PERMANENT KERNEL STACKS
// -----------------------------------------------------------------------------

/// Dedicated kernel stack stored in permanent .bss memory.
///
/// Used after bootstrap execution has completed.
var kmain_stack: [16384]u8 align(16) linksection(".bss") = undefined;

/// Dedicated shell task stack.
///
/// Stored outside the kmain() stack frame so it remains valid for the
/// lifetime of the shell task.
var shell_stack_buf: [16384]u8 align(16) = undefined;

extern const _kernel_end: u8;
extern fn isr80_stub() callconv(.c) void;

/// Halt execution permanently.
///
/// Useful for unrecoverable failures and low-level debugging.
pub fn pause() void {
    while (true) {
        asm volatile ("hlt");
    }
}

// -----------------------------------------------------------------------------
//  FREESTANDING RUNTIME SUPPORT
// -----------------------------------------------------------------------------

/// Freestanding implementation of memmove().
///
/// Required because the kernel does not link against a hosted C runtime.
/// Correctly handles overlapping source and destination ranges.
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
//  KERNEL PANIC HANDLING
// -----------------------------------------------------------------------------

/// Kernel-specific panic implementation.
///
/// Displays diagnostic information on screen and halts the processor.
/// This serves as the final error handler for unrecoverable failures.
pub const panic = std.debug.FullPanic(myPanic);

fn myPanic(msg: []const u8, return_address: ?usize) noreturn {
    vga.clearScreen(0x4, 0x0);

    vga.writeStringAt(0, 0, "KERNEL PANIC", 15, 4);

    vga.writeStringAt(2, 0, "Message: ", 14, 4);
    vga.writeStringAt(2, 9, msg, 15, 4);

    vga.writeStringAt(4, 0, "Return address: ", 14, 4);

    if (return_address) |ra| {
        var buf: [18]u8 = undefined;
        const hex = conv.toHex(usize, ra, buf[0..]);
        vga.writeStringAt(4, 17, hex, 15, 4);
    } else {
        vga.writeStringAt(4, 17, "(none)", 8, 4);
    }

    while (true) {
        asm volatile ("cli; hlt");
    }
}

/// Entry point for the shell task.
///
/// This wrapper enables interrupts for the task context and then
/// transfers control to the interactive shell loop.
///
/// If the shell unexpectedly returns, execution falls back to a
/// halted state rather than continuing into undefined behaviour.
fn shellTaskWrapper() callconv(.c) void {
    // Enable interrupts within the task's execution context.
    asm volatile ("sti");

    // Run the interactive shell.
    shell.run(&fs_global, allocator);

    // Safety fallback if the shell ever exits unexpectedly.
    while (true) {
        asm volatile ("hlt");
    }
}

// Ensure interrupt handlers are retained by the linker even when
// referenced indirectly through assembly entry points.
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
//  KERNEL ENTRY POINTS
// -----------------------------------------------------------------------------

/// Entry point invoked by the bootloader.
///
/// Performs minimal setup before transferring control to kmain().
/// This function never returns.
export fn kernel_entry() void {
    vga.clearScreen(0, 0);
    kmain();
    unreachable;
}

/// Primary kernel entry point.
///
/// Coordinates early hardware initialisation, memory management,
/// interrupt setup, storage discovery, filesystem mounting, and
/// task-system startup.
pub export fn kmain() noreturn {

    // Initialise serial output first so all subsequent diagnostic
    // messages are available regardless of video state.
    serial.init();

    const boot_info = boot_info_mod.get();

    // -------------------------------------------------------------------------
    //  FRAMEBUFFER / GRAPHICS INITIALISATION
    // -------------------------------------------------------------------------

    if (boot_info.graphics_mode == 1) {
        serial.writeString("CP1: fb.init done\n");

        fb.init(
            boot_info.framebuffer_addr,
            @intCast(boot_info.fb_stride),
                @intCast(boot_info.fb_width),
                @intCast(boot_info.fb_height),
                @intCast(boot_info.fb_bpp),
                boot_info.red_position,
                boot_info.green_position,
                boot_info.blue_position,
        );

        vga.graphics_mode = true;

        // Display the graphical startup splash screen.
        serial.writeString("CP2: splash.init done\n");
        splash.init();

        // ---------------------------------------------------------------------
        //  FRAMEBUFFER DIAGNOSTICS (RETAINED FOR HARDWARE DEBUGGING)
        // ---------------------------------------------------------------------
        //
        // These checks were used when validating framebuffer formats,
        // colour masks, channel positions, and bootloader-supplied
        // graphics information. They are intentionally preserved for
        // future graphics-driver and boot-compatibility debugging.
        //
        // Scratch buffer for conv.toHex conversions.
        // var hex_buf: [18]u8 = undefined;
        //
        // Default text colours.
        // const fg: u8 = 15;
        // const bg: u8 = 0;
        //
        // Colour mask information.
        // vga.writeStringAt(1, 0, "Red Size: ", fg, bg);
        // vga.writeStringAt(1, 10, conv.toHex(u64, boot_info.red_mask_size, &hex_buf), fg, bg);
        //
        // vga.writeStringAt(2, 0, "Red Pos: ", fg, bg);
        // vga.writeStringAt(2, 10, conv.toHex(u64, boot_info.red_position, &hex_buf), fg, bg);
        //
        // vga.writeStringAt(3, 0, "Green Size: ", fg, bg);
        // vga.writeStringAt(3, 12, conv.toHex(u64, boot_info.green_mask_size, &hex_buf), fg, bg);
        //
        // vga.writeStringAt(4, 0, "Green Pos: ", fg, bg);
        // vga.writeStringAt(4, 12, conv.toHex(u64, boot_info.green_position, &hex_buf), fg, bg);
        //
        // vga.writeStringAt(5, 0, "Blue Size: ", fg, bg);
        // vga.writeStringAt(5, 11, conv.toHex(u64, boot_info.blue_mask_size, &hex_buf), fg, bg);
        //
        // vga.writeStringAt(6, 0, "Blue Pos: ", fg, bg);
        // vga.writeStringAt(6, 11, conv.toHex(u64, boot_info.blue_position, &hex_buf), fg, bg);
        //
        // vga.writeStringAt(7, 0, "Rsvd Size: ", fg, bg);
        // vga.writeStringAt(7, 11, conv.toHex(u64, boot_info.rsvd_mask_size, &hex_buf), fg, bg);
        //
        // vga.writeStringAt(8, 0, "Rsvd Pos: ", fg, bg);
        // vga.writeStringAt(8, 11, conv.toHex(u64, boot_info.rsvd_position, &hex_buf), fg, bg);
        //
        // Framebuffer geometry and layout information.
        // vga.writeStringAt(9, 0, "FB Addr: ", fg, bg);
        // vga.writeStringAt(9, 12, conv.toHex(u64, boot_info.framebuffer_addr, &hex_buf), fg, bg);
        //
        // vga.writeStringAt(10, 0, "Stride: ", fg, bg);
        // vga.writeStringAt(10, 12, conv.toHex(u64, boot_info.fb_stride, &hex_buf), fg, bg);
        //
        // vga.writeStringAt(11, 0, "Width: ", fg, bg);
        // vga.writeStringAt(11, 12, conv.toHex(u64, boot_info.fb_width, &hex_buf), fg, bg);
        //
        // vga.writeStringAt(12, 0, "Height: ", fg, bg);
        // vga.writeStringAt(12, 12, conv.toHex(u64, boot_info.fb_height, &hex_buf), fg, bg);
        //
        // vga.writeStringAt(13, 0, "BPP: ", fg, bg);
        // vga.writeStringAt(13, 12, conv.toHex(u64, boot_info.fb_bpp, &hex_buf), fg, bg);
        //
        // pause();
    }

    // -------------------------------------------------------------------------
    //  SWITCH TO PERMANENT KERNEL STACK
    // -------------------------------------------------------------------------

    // Calculate the top of the dedicated kernel stack.
    const new_sp = @intFromPtr(&kmain_stack) + kmain_stack.len;

    // Replace the bootstrap stack with the permanent kernel stack.
    asm volatile (
        \\ movq %[stack], %%rsp
        :
        : [stack] "r" (new_sp),
    );

    // -------------------------------------------------------------------------
    //  EARLY MEMORY INITIALISATION
    // -------------------------------------------------------------------------

    @memset(&heap_buffer, 0);
    @memset(fs_ramdisk_buf, 0);

    // Initialise exception and interrupt infrastructure early.
    idt.init();

    // Initialise the Task State Segment.
    tss.init();

    splash.updateProgress(20, "Disk / File System Restore or Init...");
    splash.delay_crude(20_000_000);

    // -------------------------------------------------------------------------
    //  DISK / FILESYSTEM DISCOVERY
    // -------------------------------------------------------------------------

    var fs_exists: bool = false;
    const partition_start = conf.PARTITION_START_LBA;

    if (ata.AtaDevice.checkFileSystem(partition_start)) {
        fs_exists = true;

        //vga.writeString("CP5a: checkFileSystem returned true\n", 10, 0);

        // Diagnostic output retained for storage debugging.
        // vga.writeString("STATUS: System Partition Found!\n", 10, 0);
        // vga.writeString("RESTORE: Populating RAM from Disk...\n", 11, 0);

        // =========================================================================
        //  RAM DISK RESTORATION AND FILESYSTEM RECOVERY
        //
        //  The RAM disk acts as the live filesystem storage layer during
        //  normal operation. At boot, the filesystem image is loaded from
        //  persistent ATA storage into RAM before CodaFS is mounted.
        //
        //  Boot flow:
        //
        //    Existing filesystem:
        //      ATA disk -> RAM disk -> CodaFS mount
        //
        //    Fresh filesystem:
        //      Zeroed RAM disk -> mkfs() -> ATA backing store
        //
        //  During runtime all filesystem activity operates against the RAM
        //  disk image. Persistence is provided by synchronising updates
        //  back to the ATA-backed partition.
        //
        //  RAMDISK_SIZE must always be large enough to contain the complete
        //  filesystem image stored on disk.
        // =========================================================================

        ata.AtaDevice.readBlocks(null, partition_start, fs_ramdisk_buf[0..]) catch |err| {
            vga.writeString("ERROR: Restoration failed! Type: ", 12, 0);
            vga.writeString(@errorName(err), 12, 0);
        };

        //vga.writeString("CP5b: readBlocks done\n", 10, 0);

        const sb = @as(*coda_fs.Superblock, @ptrCast(@alignCast(&fs_ramdisk_buf[0])));

        // Check the filesystem dirty flag to determine whether the previous
        // shutdown completed cleanly.
        if ((sb.flags & coda_fs.FLAG_DIRTY) != 0) {
            //vga.writeString("WARNING: Last shutdown was UNCLEAN!\n", 14, 0);
            splash.updateProgress(33, "WARNING: Last shutdown was UNCLEAN!");
            splash.delay_crude(50_000_000);
        } else {
            vga.writeString("STATUS: Filesystem is healthy.\n", 10, 0);
        }

        // Mark the filesystem dirty immediately. The flag will be cleared
        // during a clean shutdown sequence.
        sb.flags |= coda_fs.FLAG_DIRTY;

        // Persist the updated superblock state.
        ata.AtaDevice.writeBlocks(null, partition_start, fs_ramdisk_buf[0..conf.BLOCK_SIZE]) catch {
            // Diagnostic output intentionally disabled to avoid boot noise.
            // vga.writeString("ERROR: Could not mark disk as DIRTY!\n", 12, 0);
        };

        // vga.writeString("STATUS: Filesystem Ready.\n", 10, 0);

    } else {
        fs_exists = false;

        // No valid filesystem was found. Create a fresh partition and
        // initialise a new CodaFS instance.

        // vga.writeString("STATUS: Disk is Blank.\n", 14, 0);

        // vga.writeString("Initializing MBR...\n", 15, 0);
        ata.initializePartitionTable(partition_start, 16384);

        // vga.writeString("Formatting Partition...\n", 15, 0);
        ata.formatMyFileSystem(partition_start);

        ata.AtaDevice.readBlocks(null, partition_start, fs_ramdisk_buf[0..conf.BLOCK_SIZE]) catch {};

        // Historical first-boot diagnostic.
        // vga.writeString("Done. Please close QEMU and run ./build.sh run\n", 11, 0);
    }

    // pause();

    serial.writeString("CP5: disk/filesystem check done\n");
    //vga.step(0);

    // -------------------------------------------------------------------------
    //  PHYSICAL MEMORY DISCOVERY
    // -------------------------------------------------------------------------

    splash.updateProgress(35, "Setting up memory...");

    // Copy the bootloader-provided E820 memory map into kernel-owned
    // storage before paging and allocator initialisation.
    E820Store.init();

    // Configure the E820 access layer to use the kernel-owned copy.
    e820.setTable(E820Store.getTableAddr(), E820Store.getTableCount());

    // Expose the bootstrap allocator as the kernel allocator.
    allocator = fba.allocator();

    // Build the list of usable physical memory regions using the
    // validated E820 data.
    fa.FrameAllocator.init();
    fa.FrameAllocator.parseUsableMemory();

    const regions = fa.getUsableRegions();

    // -------------------------------------------------------------------------
    //  BOOT-TIME MEMORY DIAGNOSTICS (RETAINED FOR DEBUGGING)
    // -------------------------------------------------------------------------
    //
    // The commented code below was used to verify:
    //   • Hex conversion helpers
    //   • BootInfo contents
    //   • Kernel memory layout
    //   • Raw bootloader structures
    //
    // These diagnostics are intentionally retained as reference material
    // for future low-level memory debugging.
    //

    // const x: u64 = 0x1234ABCDEF112233;
    // var buf: [16]u8 = undefined;
    // const slice = conv.toHex(u64, x, buf[0..]);

    // var len_buf: [8]u8 = undefined;
    // vga.writeString(conv.toHex(u32, @intCast(slice.len), &len_buf), 15, 0);
    // vga.writeString(slice, 15, 0);

    // const y: u32 = 0xBADFACE;
    // var buf2: [8]u8 = undefined;
    // vga.writeStringAt(3, 0, conv.toHex(u32, y, buf2[0..]), 15, 0);

    const info = bi.get();

    // var buf_start: [16]u8 = undefined;
    // vga.writeStringAt(11, 0, "Kernel start: ", 15, 0);
    // vga.writeStringAt(11, 15, conv.toHex(u64, info.kernel_start, &buf_start), 15, 0);

    // var buf_end: [16]u8 = undefined;
    // vga.writeStringAt(12, 0, "Kernel end:   ", 15, 0);
    // vga.writeStringAt(12, 15, conv.toHex(u64, info.kernel_end, &buf_end), 15, 0);

    // var buf_stack: [16]u8 = undefined;
    // vga.writeStringAt(13, 0, "Stack top:    ", 15, 0);
    // vga.writeStringAt(13, 15, conv.toHex(u64, info.stack_top, &buf_stack), 15, 0);

    // ...

    // -------------------------------------------------------------------------
    //  INTERRUPT CONTROLLER AND DEVICE IRQ SETUP
    // -------------------------------------------------------------------------

    // Install hardware interrupt gates.
    //
    // Timer, keyboard and mouse handlers are configured to use IST entry 1
    // so they always execute on a known-good interrupt stack.
    idt.setGateIst(32, @intFromPtr(&irq0_stub), 1);
    idt.setGateIst(33, @intFromPtr(&irq1_stub), 1);
    idt.setGateIst(44, @intFromPtr(&irq12_stub), 1);

    // System-call entry point.
    idt.setGate(0x80, @intFromPtr(&isr80_stub));

    // Remap the legacy PIC away from CPU exception vectors.
    pic.remap(32, 40);

    // Enable required hardware interrupt lines.
    pic.unmaskIrq(@as(u8, 0));   // PIT timer
    pic.unmaskIrq(@as(u8, 1));   // Keyboard
    pic.unmaskIrq(@as(u8, 2));   // PIC cascade
    pic.unmaskIrq(@as(u8, 12));  // Mouse

    // Initialise PS/2 mouse support.
    mouse.initMouse();

    // Configure the timer at 100 Hz.
    interrupts.init_pit(100);

    // Enable maskable interrupts globally.
    asm volatile ("sti");

    // -------------------------------------------------------------------------
    //  FRAME ALLOCATOR DIAGNOSTICS (RETAINED FOR DEBUGGING)
    // -------------------------------------------------------------------------
    //
    // Useful when validating E820 parsing, memory-region filtering and
    // frame allocator initialisation.
    //

    // var idx: usize = 0;
    // for (regions) |r| {
    //     ...
    // }

    splash.updateProgress(40, "Initialising memory...");
    splash.delay_crude(20_000_000);

    // -------------------------------------------------------------------------
    //  PHYSICAL FRAME ALLOCATOR INITIALISATION
    // -------------------------------------------------------------------------

    serial.writeString("CP3: bitmap init done\n");

    splash.updateProgress(50, "Mapping APIC hardware...");

    // Build the physical-frame bitmap using the usable memory regions
    // discovered from the E820 memory map.
    bm.init(regions);

    const mem_mod = @import("memory.zig");

    // -------------------------------------------------------------------------
    //  RESERVE KERNEL-OWNED PHYSICAL MEMORY
    // -------------------------------------------------------------------------
    //
    // Every memory range already in active use by the kernel must be
    // marked as allocated before general frame allocation begins.
    // Failure to reserve any of these regions would allow the frame
    // allocator to hand out memory that is already in use.
    //

    // Kernel image (.text, .rodata, .data, .bss, etc.).
    const real_kernel_end_virt = @intFromPtr(&_kernel_end);
    const real_kernel_end_phys = mem_mod.virtToPhys(real_kernel_end_virt);
    bm.markUsedRange(info.kernel_start, real_kernel_end_phys);

    // Bootstrap kernel stack supplied by the boot process.
    bm.markUsedRange(info.stack_top - STACK_SIZE, info.stack_top);

    // FixedBufferAllocator backing heap.
    const heap_virt = @intFromPtr(&heap_buffer[0]);
    const heap_phys = mem_mod.virtToPhys(heap_virt);
    bm.markUsedRange(heap_phys, heap_phys + heap_buffer.len);

    // Kernel-owned E820 memory map copy.
    const e820_start = E820Store.getTableAddr();
    const e820_end =
    e820_start +
    @as(usize, E820Store.getTableCount()) * @sizeOf(E820Store.E820Entry);

    bm.markUsedRange(e820_start, e820_end);

    // Physical storage occupied by the frame-allocation bitmap itself.
    const range = bm.getStorageRange();
    bm.markUsedRange(range.start, range.end);

    // Reserved page-table memory.
    bm.markUsedRange(
        info.page_table_base,
        info.page_table_base + PAGE_TABLE_BYTES,
    );

    // RAM disk backing storage.
    const ramdisk_virt = @intFromPtr(&fs_ramdisk_buf[0]);
    const ramdisk_phys = mem_mod.virtToPhys(ramdisk_virt);
    bm.markUsedRange(ramdisk_phys, ramdisk_phys + fs_ramdisk_buf.len);

    // Bitmap-storage diagnostics retained for allocator debugging.
    //
    // const bmRange = bm.getStorageRange();
    // var buf_bm_range: [16]u8 = undefined;
    // vga.writeString("Bitmap start: 0x", 15, 0);
    // vga.writeString(conv.toHex(u64, bmRange.start, &buf_bm_range), 15, 0);
    // vga.writeString("Bitmap end:   0x", 15, 0);
    // vga.writeString(conv.toHex(u64, bmRange.end, &buf_bm_range), 15, 0);

    // Dedicated shell-task stack.
    //
    // This stack remains active for the lifetime of the shell task and
    // is separate from the bootstrap kernel stack reserved above.
    const shell_stack_virt = @intFromPtr(&shell_stack_buf[0]);
    const shell_stack_phys = mem_mod.virtToPhys(shell_stack_virt);
    bm.markUsedRange(shell_stack_phys, shell_stack_phys + shell_stack_buf.len);

    // Scratch page used for loading and executing external binaries.
    bm.markUsedRange(0x7000, 0x8000);

    // Task State Segment and dedicated IST1 interrupt stack.
    bm.markUsedRange(0x20000, 0x29000);

    // Clear the binary-loader scratch page so execution metadata
    // always begins in a known state.
    const scratch_virt = memory.physToVirt(0x7000);
    const scratch_ptr: [*]u8 = @ptrFromInt(scratch_virt);
    @memset(scratch_ptr[0..4096], 0);

    splash.updateProgress(60, "Configuring interrupts...");
    splash.delay_crude(20_000_000);

    // -------------------------------------------------------------------------
    //  APIC VIRTUAL MEMORY MAPPING
    // -------------------------------------------------------------------------

    // Read the currently active page-table root from CR3 so that APIC
    // mappings can be added to the running address space.
    var cr3: usize = 0;
    asm volatile ("mov %%cr3, %[cr3]" : [cr3] "=r" (cr3));

    // Map the Local APIC MMIO region.
    mem_mod.mapPage(
        cr3,
        apic.LAPIC_VIRT_BASE,
        apic.LAPIC_PHYS_BASE,
        mem_mod.FLAGS_MMIO,
    ) catch {
        @panic("Failed to dynamically map Local APIC");
    };

    // Map the I/O APIC MMIO region.
    mem_mod.mapPage(
        cr3,
        apic.IOAPIC_VIRT_BASE,
        apic.IOAPIC_PHYS_BASE,
        mem_mod.FLAGS_MMIO,
    ) catch {
        @panic("Failed to dynamically map I/O APIC");
    };

    serial.writeString("CP4: APIC mapped\n");
    //vga.writeString("APIC Hardware Mapped Safely!", 15, 0);

    // -------------------------------------------------------------------------
    //  APIC INITIALISATION AND ACTIVATION
    // -------------------------------------------------------------------------

    splash.updateProgress(65, "APIC feature probe...");

    apic.enableApicSoftware();
    apic.initLapicTimer(0x20);
    apic.initIoApicKeyboard();
    apic.initIoApicMouse();

    // Route interrupt acknowledgements through the APIC subsystem
    // once initialisation has completed successfully.
    conf.timer.use_apic = true;

    // Verify communication with the Local APIC.
    //const lapic_id = apic.probeApicId();

    //vga.writeStringAt(1, 0, "LAPIC Active Core ID: ", 0x0A, 0);

    //var id_buf: [16]u8 = undefined;
    //const id_str = conv.u32ToStr(&id_buf, lapic_id);
    //vga.writeStringAt(1, 22, id_str, 0x0E, 0);

    // Read and display the bootstrap processor's APIC identifier.
    //const core_id = apic.probeApicId();

    //var buf_id: [16]u8 = undefined;
    //vga.writeString(" -> Detected Bootstrap Core APIC ID: ", 15, 0);
    //vga.writeString(conv.toHex(u64, core_id, &buf_id), 15, 0);

    // -------------------------------------------------------------------------
    //  APIC HARDWARE DIAGNOSTICS (RETAINED FOR DEBUGGING)
    // -------------------------------------------------------------------------
    //
    // These checks were used during APIC bring-up to verify MMIO
    // mappings, LAPIC register access, and I/O APIC visibility.
    //
    // vga.clearScreen(0, 0);
    // vga.writeString("A\r\n", 15, 0);
    //
    // const raw_lapic = apic.debugRawLapic();
    // vga.writeString("B\r\n", 15, 0);
    //
    // const raw_ioapic = apic.debugRawIoApic();
    // vga.writeString("C\r\n", 15, 0);
    //
    // var buf_l: [16]u8 = undefined;
    // var buf_i: [16]u8 = undefined;
    // vga.writeString("RAW LAPIC: ", 15, 0);
    // vga.writeString(conv.toHex(u64, raw_lapic, &buf_l), 15, 0);
    // vga.writeString(" RAW IOAPIC: ", 15, 0);
    // vga.writeString(conv.toHex(u64, raw_ioapic, &buf_i), 15, 0);
    // vga.writeString("D\r\n", 15, 0);

    // -------------------------------------------------------------------------
    //  FRAME ALLOCATOR SELF-TEST
    // -------------------------------------------------------------------------

    splash.updateProgress(75, "Frame allocator self-test...");

    // Validate allocation, deallocation, and reuse behaviour before
    // the allocator is relied upon by higher-level subsystems.

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
        //vga.writeString("Allocator reuse OK", 15, 2);
        vga.writeString("ARO", 0, 0);
    } else {
        //vga.writeString("Allocator not reusing frames!", 15, 4);
        vga.writeString("ANRF", 0, 0);
    }

    bm.freeFrame(reused);

    // Display current keyboard-controller state for debugging.
    //var buf_status: [16]u8 = undefined;
    //const status = io.inb(0x64);

    //vga.writeString("KBC status: ", 15, 0);
    //vga.writeString(conv.toHex(u64, status, &buf_status), 15, 0);

    // Optional panic-path validation.
    const FORCE_PANIC = false;
    if (FORCE_PANIC) {
        @panic("TEST");
    }

    asm volatile ("sti");

    splash.updateProgress(80, "Task manager initialising...");
    splash.delay_crude(20_000_000);

    // =========================================================================
    //  TASK SCHEDULER INITIALISATION
    // =========================================================================

    // Create the global scheduler using the kernel allocator.
    scheduler.manager = scheduler.Scheduler.init(allocator);

    // Optionally register the currently executing kernel thread as
    // the initial scheduler-managed task.
    if (conf.USE_SCHEDULER_SHELL) {
        scheduler.manager.registerCurrentThreadAsTask(0, 0);
        scheduler.manager.current_task_idx = 0;
    }

    splash.updateProgress(100, "Final setup...");
    splash.delay_crude(20_000_000);

    // =========================================================================
    //  FILESYSTEM MOUNT AND APPLICATION STAGING
    // =========================================================================

    // Expose the RAM disk image as a block device and mount the
    // filesystem on top of it.
    var ram_disk = @import("fs/ramdisk.zig").RamDisk.init(fs_ramdisk_buf[0..], 512);
    var dev = ram_disk.asBlockDevice();

    // Create a fresh filesystem if no valid installation was found.
    if (!fs_exists) {
        CodaFs.mkfs(allocator, &dev) catch |err| {
            @panic(@errorName(err));
        };
    }

    const fs = CodaFs.mount(allocator, &dev) catch |err| {
        vga.writeString("Mount failed: ", 12, 4);
        @panic(@errorName(err));
    };

    // Populate the global filesystem instance from the mounted volume.
    fs_global.device = fs.device;
    fs_global.superblock = fs.superblock;
    fs_global.space_manager = fs.space_manager;
    fs_global.root_dir = fs.root_dir;

    // Install applications embedded within the kernel image into the
    // filesystem if they are not already present.
    bin_loader.installEmbeddedApps(allocator, &fs_global) catch |err| {
        vga.writeString("Application injection failure: ", 12, 5);
        vga.writeString(@errorName(err), 12, 5);
        vga.writeString("\n", 12, 5);
    };

    // -------------------------------------------------------------------------
    //  FILESYSTEM VALIDATION TEST
    // -------------------------------------------------------------------------
    //
    // Performs a simple read-path verification against an installed
    // application image. Useful for catching early filesystem,
    // block-device, and loader regressions.
    //

    // vga.writeString("\n🔍 Verifying prog1.bin read...", 10, 6);

    // Allocate a test buffer large enough to hold the file.
    const test_buf = allocator.alloc(u8, 4236) catch |err| {
        @panic(@errorName(err));
    };
    defer allocator.free(test_buf);

    // Read a known embedded application from the filesystem.
    const bytes_read = fs_global.readFile(allocator, "/prog1", test_buf) catch |err| {
        vga.writeString("\n❌ Read failed: ", 12, 7);
        vga.writeString(@errorName(err), 12, 7);
        @panic(@errorName(err));
    };

    // The successful read is currently used only as a validation check.
    _ = bytes_read;

    // vga.writeString("\n✅ Read successful!", 10, 8);

    // Touch the buffer to make its use explicit during validation.
    for (test_buf[0..4]) |_| {
        // Intentionally empty.
    }

    // pause();

    // Remove the startup splash screen and transition to normal UI.
    splash.dismiss();

    // =========================================================================
    //  SHELL AND USERLAND HANDOFF
    // =========================================================================

    serial.writeString("CP6: about to call shell.run()\n");

    if (conf.USE_SCHEDULER_SHELL) {

        // Calculate the top of the dedicated shell task stack.
        const stack_top = @intFromPtr(&shell_stack_buf) + shell_stack_buf.len;

        // Switch execution from the bootstrap kernel stack to the
        // shell task's permanent stack.
        //
        // From this point onward, shell execution is completely
        // isolated from the early-boot stack environment.
        asm volatile (
            \\ mov %[top], %%rsp
            \\ xor %%rbp, %%rbp
            :
            : [top] "r" (stack_top)
            : .{}
        );

        // Register the current execution context as Task 0.
        scheduler.manager.registerCurrentThreadAsTask(0, 0);
        scheduler.manager.current_task_idx = 0;

        // Enable scheduler-driven preemption.
        scheduler.manager.yield_enabled = true;

        // Ensure hardware interrupts are enabled before entering the
        // interactive environment.
        asm volatile ("sti");

        // Transfer control to the shell.
        //
        // All subsequent stack allocations occur within the dedicated
        // shell stack rather than the bootstrap kernel stack.
        shell.run(&fs_global, allocator);

        while (true) {
            asm volatile ("hlt");
        }

    } else {

        // Scheduler-disabled mode.
        //
        // The shell runs directly without task switching or preemption.
        scheduler.manager.yield_enabled = false;
        shell.run(&fs_global, allocator);
    }

    // -------------------------------------------------------------------------
    //  OPTIONAL DEVELOPMENT TESTS
    // -------------------------------------------------------------------------

    const ENABLE_TESTS = false;

    if (ENABLE_TESTS) {
        tests.runAllocatorTests(allocator);
        // vga.step(7);
    }

    // The kernel should never return past shell execution.
    while (true) {
        asm volatile ("hlt");
    }
}
