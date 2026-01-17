// src/kernel/tests.zig
//
// This module contains small, self‑contained tests for:
//   • CPU exceptions (divide‑by‑zero, invalid opcode, GPF, etc.)
//   • Basic allocator behaviour
//
// These tests intentionally crash the kernel when triggered.
// They are meant for early debugging only.

const vga = @import("vga.zig");
const std = @import("std");

// ------------------------------------------------------------
// Exception Tests
// ------------------------------------------------------------

/// Force a divide‑by‑zero exception using inline assembly.
pub fn trigger_divide_by_zero() void {
    vga.clearScreen(15, 0);
    vga.writeStringAt(3, 0, "About to divide...", 15, 0);

    asm volatile (
        \\mov $10, %%eax
        \\xor %%edx, %%edx
        \\xor %%ecx, %%ecx
        \\div %%ecx
    );

    // Should never reach here
    vga.writeStringAt(4, 0, "After divide (shouldn't see this)", 15, 0);
}

/// Trigger a breakpoint exception (INT3).
pub fn test_breakpoint() void {
    vga.writeStringAt(3, 0, "Testing breakpoint...", 15, 0);
    asm volatile ("int3");
    vga.writeStringAt(4, 0, "After breakpoint", 15, 0);
}

/// Trigger an invalid opcode exception.
pub fn test_invalid_opcode() void {
    vga.writeStringAt(3, 0, "Testing invalid opcode...", 15, 0);
    asm volatile ("ud2"); // guaranteed invalid instruction
    vga.writeStringAt(4, 0, "After invalid opcode (shouldn't see)", 15, 0);
}

/// Trigger a General Protection Fault by loading an invalid segment selector.
pub fn test_gpf() void {
    vga.writeStringAt(3, 0, "Testing GPF...", 15, 0);
    asm volatile ("mov $0x99, %ax; mov %ax, %ds");
    vga.writeStringAt(4, 0, "After GPF (shouldn't see)", 15, 0);
}

/// Trigger a page fault by accessing an unmapped address.
pub fn test_page_fault() void {
    vga.writeStringAt(3, 0, "Testing page fault...", 15, 0);

    const bad_ptr = @as(*volatile u8, @ptrFromInt(0xFFFFFFFF00000000));
    _ = bad_ptr.*; // guaranteed page fault

    vga.writeStringAt(4, 0, "After page fault (shouldn't see)", 15, 0);
}

// ------------------------------------------------------------
// Allocator Tests
// ------------------------------------------------------------

/// Copy a short message into a buffer (used for allocator tests).
fn writeTestMessage(buf: []u8, text: []const u8) void {
    const len = @min(buf.len, text.len);
    std.mem.copyForwards(u8, buf[0..len], text[0..len]);
}

/// Run a series of simple allocator tests using a std.mem.Allocator.
///
/// Tests:
///   1. Allocate 128 bytes
///   2. Allocate 256 bytes
///   3. Allocate 512 bytes
///   4. Allocate 64 bytes with 4096‑byte alignment
///   5. Attempt a huge allocation to confirm OOM behaviour
pub fn runAllocatorTests(allocator: std.mem.Allocator) void {
    // -------------------------
    // Test 1 — 128 bytes
    // -------------------------
    const d128 = allocator.alloc(u8, 128) catch {
        vga.writeString("Alloc 128 failed", 15, 0);
        return;
    };
    writeTestMessage(d128, "Allocated 128 bytes");
    vga.writeString(d128, 15, 0);

    // -------------------------
    // Test 2 — 256 bytes
    // -------------------------
    const d256 = allocator.alloc(u8, 256) catch {
        vga.writeString("Alloc 256 failed", 15, 0);
        return;
    };
    writeTestMessage(d256, "Allocated 256 bytes");
    vga.writeString(d256, 15, 0);

    // -------------------------
    // Test 3 — 512 bytes
    // -------------------------
    const d512 = allocator.alloc(u8, 512) catch {
        vga.writeString("Alloc 512 failed", 15, 0);
        return;
    };
    writeTestMessage(d512, "Allocated 512 bytes");
    vga.writeString(d512, 15, 0);

    // -------------------------
    // Test 4 — aligned allocation (4096‑byte alignment)
    // -------------------------
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

    // -------------------------
    // Test 5 — Out‑of‑memory test
    // -------------------------
    const too_big = allocator.alloc(u8, 10 * 1024 * 1024) catch {
        vga.writeString("OOM test passed", 15, 0);
        return;
    };

    // If this prints, something is wrong
    writeTestMessage(too_big, "Unexpected success");
    vga.writeString(too_big, 15, 0);
}
