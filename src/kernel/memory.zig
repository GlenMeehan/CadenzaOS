// src/kernel/memory.zig
//
// Core memory helpers for the kernel.
// Provides:
//   • physToVirt / virtToPhys — direct‑map conversions
//   • memcpy / memset         — exported for freestanding Zig builds
//   • eqlNoSimd               — simple byte‑wise equality check
//
// Notes:
//   • memcpy/memset are intentionally simple and unoptimized.
//   • They must remain `pub export` so the linker can resolve them
//     when Zig emits calls in freestanding mode.

const bm = @import("bitmap.zig");
pub const KERNEL_OFFSET: usize = 0xFFFFFF8000000000;

// -----------------------------------------------------------------------------
//  ADDRESS TRANSLATION
// -----------------------------------------------------------------------------

/// Convert a physical address to a higher‑half virtual address.
pub fn physToVirt(phys: usize) usize {
    return phys + KERNEL_OFFSET;
}

/// Convert a higher‑half virtual address back to physical.
pub fn virtToPhys(virt: usize) usize {
    return virt - KERNEL_OFFSET;
}

// -----------------------------------------------------------------------------
//  BASIC MEMORY ROUTINES (exported for Zig freestanding)
// -----------------------------------------------------------------------------

/// Simple byte‑wise memcpy.
/// Required because Zig's stdlib expects `memcpy` to exist in freestanding mode.
pub export fn memcpy(dest: [*]u8, src: [*]const u8, n: usize) [*]u8 {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        dest[i] = src[i];
    }
    return dest;
}

/// Simple byte‑wise memset.
/// Required because Zig's stdlib expects `memset` to exist in freestanding mode.
pub export fn memset(dest: [*]u8, value: u8, n: usize) [*]u8 {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        dest[i] = value;
    }
    return dest;
}

// -----------------------------------------------------------------------------
//  SLICE EQUALITY (no SIMD)
// -----------------------------------------------------------------------------

/// Compare two slices element‑by‑element.
/// Returns true only if lengths match and all elements match.
pub fn eqlNoSimd(comptime T: type, a: []const T, b: []const T) bool {
    if (a.len != b.len) return false;
    if (a.ptr == b.ptr) return true;

    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}


// -----------------------------------------------------------------------------
//  VIRTUAL ADDRESS UNPACKING INDEXERS
// -----------------------------------------------------------------------------

/// Extract the 9-bit PML4 index from a virtual address (Bits 39-47)
pub inline fn pml4Index(virt: usize) usize {
    return (virt >> 39) & 0x1FF;
}

/// Extract the 9-bit PDPT index from a virtual address (Bits 30-38)
pub inline fn pdptIndex(virt: usize) usize {
    return (virt >> 30) & 0x1FF;
}

/// Extract the 9-bit PD index from a virtual address (Bits 21-29)
pub inline fn pdIndex(virt: usize) usize {
    return (virt >> 21) & 0x1FF;
}

/// Extract the 9-bit PT index from a virtual address (Bits 12-20)
pub inline fn ptIndex(virt: usize) usize {
    return (virt >> 12) & 0x1FF;
}

// Standard x86_64 Page Entry Flags
pub const PAGE_PRESENT: u64 = 1 << 0;
pub const PAGE_WRITABLE: u64 = 1 << 1;

/// Safely navigates the 4-level page hierarchy, dynamically allocating
/// intermediate tables if they are missing, and maps a 4 KiB page.
pub fn mapPage(pml4_phys: usize, virt: usize, phys: usize, flags: u64) !void {
    // 1. Get the virtual address of the PML4 base table
    const pml4_virt = physToVirt(pml4_phys);
    const pml4 = @as([*]volatile u64, @ptrFromInt(pml4_virt));

    // 2. Navigate / Create PDPT
    const pml4_idx = pml4Index(virt);
    if ((pml4[pml4_idx] & PAGE_PRESENT) == 0) {
        // Table missing! Allocate a raw frame via your bitmap allocator
        const new_table_phys = bm.allocFrame() orelse return error.OutOfMemory;
        const new_table =
        @as([*]u8, @ptrFromInt(physToVirt(new_table_phys)));

        @memset(new_table[0..4096], 0);
        pml4[pml4_idx] = new_table_phys | PAGE_PRESENT | PAGE_WRITABLE;
    }
    const pdpt_phys = pml4[pml4_idx] & 0x000FFFFFFFFFF000;

    // 3. Navigate / Create PD
    const pdpt_virt = physToVirt(pdpt_phys);
    const pdpt = @as([*]volatile u64, @ptrFromInt(pdpt_virt));
    const pdpt_idx = pdptIndex(virt);
    if ((pdpt[pdpt_idx] & PAGE_PRESENT) == 0) {
        const new_table_phys = bm.allocFrame() orelse return error.OutOfMemory;
        const new_table =
        @as([*]u8, @ptrFromInt(physToVirt(new_table_phys)));

        @memset(new_table[0..4096], 0);
        pdpt[pdpt_idx] = new_table_phys | PAGE_PRESENT | PAGE_WRITABLE;
    }
    const pd_phys = pdpt[pdpt_idx] & 0x000FFFFFFFFFF000;

    // 4. Navigate / Create PT
    const pd_virt = physToVirt(pd_phys);
    const pd = @as([*]volatile u64, @ptrFromInt(pd_virt));
    const pd_idx = pdIndex(virt);
    if ((pd[pd_idx] & PAGE_PRESENT) == 0) {
        const new_table_phys = bm.allocFrame() orelse return error.OutOfMemory;
        const new_table =
        @as([*]u8, @ptrFromInt(physToVirt(new_table_phys)));

        @memset(new_table[0..4096], 0);
        pd[pd_idx] = new_table_phys | PAGE_PRESENT | PAGE_WRITABLE;
    }
    const pt_phys = pd[pd_idx] & 0x000FFFFFFFFFF000;

    // 5. Finally, set the target Page Table Entry (PTE)
    const pt_virt = physToVirt(pt_phys);
    const pt = @as([*]volatile u64, @ptrFromInt(pt_virt));
    const pt_idx = ptIndex(virt);

    pt[pt_idx] = (phys & 0x000FFFFFFFFFF000) | flags;

    // FLUSH THE TLB IMMEDIATELY FOR THIS ADDRESS
    flushTlb(virt);
}

/// Tells the CPU to invalidate its translation cache (TLB) for a specific virtual address.
pub inline fn flushTlb(virt: usize) void {
    asm volatile ("invlpg (%%rax)"
    :
    : [virt] "{rax}" (virt)
    : .{ .memory = true }
    );
}

// Advanced x86_64 Page Flags for Hardware MMIO
pub const PAGE_CACHE_DISABLE: u64 = 1 << 4;
pub const PAGE_WRITE_THROUGH: u64 = 1 << 3;

// Combined flags for secure device register access
pub const FLAGS_MMIO = PAGE_PRESENT | PAGE_WRITABLE | PAGE_CACHE_DISABLE | PAGE_WRITE_THROUGH;
