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
