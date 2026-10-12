// src/kernel/memory.zig
//
// Core memory-management helpers used throughout the kernel.
//
// Provides:
//   • physToVirt / virtToPhys — higher-half direct-map conversions
//   • memcpy / memset         — freestanding runtime implementations
//   • eqlNoSimd              — generic byte-wise equality checking
//   • mapPage                — dynamic 4-level page-table mapping
//   • flushTlb               — invalidate cached address translations
//
// Notes:
//   • memcpy() and memset() are intentionally simple bootstrap
//     implementations with no architecture-specific optimisations.
//   • Both functions remain exported so Zig's freestanding runtime
//     can resolve generated memory-operation calls.
//
const bm = @import("bitmap.zig");

/// Base virtual address of the kernel higher-half direct map.
pub const KERNEL_OFFSET: usize = 0xFFFFFF8000000000;

// -----------------------------------------------------------------------------
//  ADDRESS TRANSLATION
// -----------------------------------------------------------------------------

/// Convert a physical address into its higher-half virtual mapping.
pub fn physToVirt(phys: usize) usize {
    return phys + KERNEL_OFFSET;
}

/// Convert a higher-half virtual address back to its physical address.
pub fn virtToPhys(virt: usize) usize {
    return virt - KERNEL_OFFSET;
}

// -----------------------------------------------------------------------------
//  FREESTANDING MEMORY ROUTINES
// -----------------------------------------------------------------------------

/// Simple byte-wise memcpy implementation.
///
/// Required because freestanding Zig builds may emit calls to memcpy()
/// even when no hosted runtime or libc is available.
pub export fn memcpy(dest: [*]u8, src: [*]const u8, n: usize) [*]u8 {
    var i: usize = 0;

    while (i < n) : (i += 1) {
        dest[i] = src[i];
    }

    return dest;
}

/// Simple byte-wise memset implementation.
///
/// Required because freestanding Zig builds may emit calls to memset()
/// even when no hosted runtime or libc is available.
pub export fn memset(dest: [*]u8, value: u8, n: usize) [*]u8 {
    var i: usize = 0;

    while (i < n) : (i += 1) {
        dest[i] = value;
    }

    return dest;
}

// -----------------------------------------------------------------------------
//  SLICE COMPARISON
// -----------------------------------------------------------------------------

/// Compare two slices element-by-element.
///
/// Returns true only when both slices have the same length and every
/// element compares equal.
pub fn eqlNoSimd(comptime T: type, a: []const T, b: []const T) bool {
    if (a.len != b.len) return false;

    // Identical backing storage is always equal.
    if (a.ptr == b.ptr) return true;

    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }

    return true;
}

// -----------------------------------------------------------------------------
//  PAGE-TABLE INDEX EXTRACTION
// -----------------------------------------------------------------------------

/// Extract the PML4 index (bits 39-47) from a canonical x86_64
/// virtual address.
pub inline fn pml4Index(virt: usize) usize {
    return (virt >> 39) & 0x1FF;
}

/// Extract the PDPT index (bits 30-38) from a canonical x86_64
/// virtual address.
pub inline fn pdptIndex(virt: usize) usize {
    return (virt >> 30) & 0x1FF;
}

/// Extract the Page Directory index (bits 21-29) from a canonical
/// x86_64 virtual address.
pub inline fn pdIndex(virt: usize) usize {
    return (virt >> 21) & 0x1FF;
}

/// Extract the Page Table index (bits 12-20) from a canonical
/// x86_64 virtual address.
pub inline fn ptIndex(virt: usize) usize {
    return (virt >> 12) & 0x1FF;
}

// -----------------------------------------------------------------------------
//  PAGE-TABLE FLAGS
// -----------------------------------------------------------------------------

/// Page is present in physical memory.
pub const PAGE_PRESENT: u64 = 1 << 0;

/// Page is writable.
pub const PAGE_WRITABLE: u64 = 1 << 1;

/// Walk the x86_64 four-level paging hierarchy and map a single
/// 4 KiB page.
///
/// Any missing intermediate paging structures are allocated on demand
/// using the bitmap frame allocator.
///
/// Hierarchy:
///   PML4 -> PDPT -> PD -> PT -> Page
pub fn mapPage(pml4_phys: usize, virt: usize, phys: usize, flags: u64) !void {

    // Access the active PML4 via the higher-half direct mapping.
    const pml4_virt = physToVirt(pml4_phys);
    const pml4 = @as([*]volatile u64, @ptrFromInt(pml4_virt));

    // -------------------------------------------------------------------------
    //  PML4 -> PDPT
    // -------------------------------------------------------------------------

    const pml4_idx = pml4Index(virt);

    if ((pml4[pml4_idx] & PAGE_PRESENT) == 0) {

        // Allocate a new Page Directory Pointer Table.
        const new_table_phys = bm.allocFrame() orelse return error.OutOfMemory;

        const new_table =
        @as([*]u8, @ptrFromInt(physToVirt(new_table_phys)));

        @memset(new_table[0..4096], 0);

        pml4[pml4_idx] = new_table_phys | PAGE_PRESENT | PAGE_WRITABLE;
    }

    const pdpt_phys = pml4[pml4_idx] & 0x000FFFFFFFFFF000;

    // -------------------------------------------------------------------------
    //  PDPT -> PD
    // -------------------------------------------------------------------------

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

    // -------------------------------------------------------------------------
    //  PD -> PT
    // -------------------------------------------------------------------------

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

    // -------------------------------------------------------------------------
    //  FINAL PAGE-TABLE ENTRY
    // -------------------------------------------------------------------------

    const pt_virt = physToVirt(pt_phys);
    const pt = @as([*]volatile u64, @ptrFromInt(pt_virt));

    const pt_idx = ptIndex(virt);

    pt[pt_idx] = (phys & 0x000FFFFFFFFFF000) | flags;

    // Invalidate any cached translation for this virtual address.
    flushTlb(virt);
}

/// Invalidate the processor's Translation Lookaside Buffer (TLB)
/// entry for a single virtual address.
///
/// Required after modifying active page tables so the CPU observes
/// the updated mapping.
pub inline fn flushTlb(virt: usize) void {
    asm volatile ("invlpg (%%rax)"
    :
    : [virt] "{rax}" (virt)
    : .{ .memory = true }
    );
}

// -----------------------------------------------------------------------------
//  MMIO PAGE FLAGS
// -----------------------------------------------------------------------------

/// Disable CPU caching for the mapped page.
pub const PAGE_CACHE_DISABLE: u64 = 1 << 4;

/// Enable write-through cache behaviour.
pub const PAGE_WRITE_THROUGH: u64 = 1 << 3;

/// Recommended flags for memory-mapped device registers.
///
/// Used for APICs and other MMIO regions where CPU caching would
/// interfere with hardware-visible state changes.
pub const FLAGS_MMIO =
PAGE_PRESENT |
PAGE_WRITABLE |
PAGE_CACHE_DISABLE |
PAGE_WRITE_THROUGH;
