// src/kernel/tests.zig
//
// Standalone kernel validation tests.
//
// Provides tests for:
//   • CPU exception and fault handling
//   • Allocator behaviour and failure paths
//
// Many of the exception tests intentionally trigger fatal processor
// faults and are expected to terminate normal execution. They are
// intended for bring-up, debugging, and validation of exception
// handling infrastructure.
//
const vga = @import("vga.zig");
const std = @import("std");

// -----------------------------------------------------------------------------
//  EXCEPTION AND FAULT TESTS
// -----------------------------------------------------------------------------

/// Trigger a divide-by-zero fault.
///
/// Verifies that exception vector 0 is correctly installed and that
/// fault handling behaves as expected.
pub fn trigger_divide_by_zero() void {
    vga.clearScreen(15, 0);
    vga.writeStringAt(3, 0, "About to divide...", 15, 0);

    asm volatile (
        \\mov $10, %%eax
        \\xor %%edx, %%edx
        \\xor %%ecx, %%ecx
        \\div %%ecx
    );

    // Execution should never reach this point.
    vga.writeStringAt(4, 0, "After divide (shouldn't see this)", 15, 0);
}

/// Trigger a breakpoint exception (INT3).
///
/// Useful when testing interrupt dispatch and debugger integration.
pub fn test_breakpoint() void {
    vga.writeStringAt(3, 0, "Testing breakpoint...", 15, 0);

    asm volatile ("int3");

    vga.writeStringAt(4, 0, "After breakpoint", 15, 0);
}

/// Trigger an invalid-opcode fault.
///
/// Verifies handling of CPU-detected illegal instructions.
pub fn test_invalid_opcode() void {
    vga.writeStringAt(3, 0, "Testing invalid opcode...", 15, 0);

    asm volatile ("ud2"); // Guaranteed invalid instruction

    vga.writeStringAt(4, 0, "After invalid opcode (shouldn't see)", 15, 0);
}

/// Trigger a General Protection Fault (GPF).
///
/// This is accomplished by loading an invalid segment selector.
pub fn test_gpf() void {
    vga.writeStringAt(3, 0, "Testing GPF...", 15, 0);

    asm volatile ("mov $0x99, %ax; mov %ax, %ds");

    vga.writeStringAt(4, 0, "After GPF (shouldn't see)", 15, 0);
}

/// Trigger a page fault by accessing an unmapped address.
///
/// Useful for validating page-fault handling and diagnostic output.
pub fn test_page_fault() void {
    vga.writeStringAt(3, 0, "Testing page fault...", 15, 0);

    const bad_ptr = @as(*volatile u8, @ptrFromInt(0xFFFFFFFF00000000));

    _ = bad_ptr.*; // Expected page fault

    vga.writeStringAt(4, 0, "After page fault (shouldn't see)", 15, 0);
}

// -----------------------------------------------------------------------------
//  ALLOCATOR TEST HELPERS
// -----------------------------------------------------------------------------

/// Copy a short text message into a writable buffer.
///
/// Used by allocator validation tests to confirm that allocated
/// memory is writable and retains expected contents.
fn writeTestMessage(buf: []u8, text: []const u8) void {
    const len = @min(buf.len, text.len);
    std.mem.copyForwards(u8, buf[0..len], text[0..len]);
}

// -----------------------------------------------------------------------------
//  ALLOCATOR VALIDATION
// -----------------------------------------------------------------------------

/// Execute a series of basic allocator validation tests.
///
/// Test coverage:
///   1. Allocate 128 bytes
///   2. Allocate 256 bytes
///   3. Allocate 512 bytes
///   4. Allocate memory with page alignment
///   5. Verify out-of-memory handling
///
/// Success and failure information is written directly to the display.
pub fn runAllocatorTests(allocator: std.mem.Allocator) void {

    // -------------------------------------------------------------------------
    //  TEST 1 - 128 BYTE ALLOCATION
    // -------------------------------------------------------------------------

    const d128 = allocator.alloc(u8, 128) catch {
        vga.writeString("Alloc 128 failed", 15, 0);
        return;
    };

    writeTestMessage(d128, "Allocated 128 bytes");
    vga.writeString(d128, 15, 0);

    // -------------------------------------------------------------------------
    //  TEST 2 - 256 BYTE ALLOCATION
    // -------------------------------------------------------------------------

    const d256 = allocator.alloc(u8, 256) catch {
        vga.writeString("Alloc 256 failed", 15, 0);
        return;
    };

    writeTestMessage(d256, "Allocated 256 bytes");
    vga.writeString(d256, 15, 0);

    // -------------------------------------------------------------------------
    //  TEST 3 - 512 BYTE ALLOCATION
    // -------------------------------------------------------------------------

    const d512 = allocator.alloc(u8, 512) catch {
        vga.writeString("Alloc 512 failed", 15, 0);
        return;
    };

    writeTestMessage(d512, "Allocated 512 bytes");
    vga.writeString(d512, 15, 0);

    // -------------------------------------------------------------------------
    //  TEST 4 - PAGE-ALIGNED ALLOCATION
    // -------------------------------------------------------------------------

    const align_val = 4096;
    const log2 = std.math.log2(align_val);

    const aligned = allocator.alignedAlloc(
        u8,
        @enumFromInt(log2),
                                           64,
    ) catch {
        vga.writeString("Aligned alloc failed", 15, 0);
        return;
    };

    writeTestMessage(aligned, "Aligned 4096 alloc");
    vga.writeString(aligned, 15, 0);

    // -------------------------------------------------------------------------
    //  TEST 5 - OUT-OF-MEMORY HANDLING
    // -------------------------------------------------------------------------

    const too_big = allocator.alloc(u8, 10 * 1024 * 1024) catch {
        vga.writeString("OOM test passed", 15, 0);
        return;
    };

    // Reaching this point indicates that the expected allocation
    // failure did not occur.
    writeTestMessage(too_big, "Unexpected success");
    vga.writeString(too_big, 15, 0);
}
