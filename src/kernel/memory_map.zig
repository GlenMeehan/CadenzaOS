// src/kernel.zig (helper)
//
// Mark all usable pages from the E820 map as free in the physical bitmap.
// This is an older approach that manually walks the E820 table and frees
// each 4 KiB page. Modern code uses bitmap.init(regions) instead.
//
// NOTE: This function is likely redundant now.

fn markUsableFromE820() void {
    var iter = e820.iterate();
    var region_count: u32 = 0;

    while (iter.next()) |entry| {
        // Only type 1 = usable RAM
        if (entry.entry_type != 1) continue;

        region_count += 1;

        // Debug: show which region is being processed
        var buf: [8]u8 = undefined;
        vga.writeStringAt(20, 0, "Processing region: ", 15, 0);
        vga.writeStringAt(20, 19, conv.toHex(u32, region_count, &buf), 15, 0);

        // Physical address range
        var addr: u64 = entry.base;
        const end: u64 = entry.base + entry.length;

        // Align start to the next page boundary
        addr = (addr + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);

        // Mark each page as free
        while (addr + PAGE_SIZE <= end) : (addr += PAGE_SIZE) {
            const phys_addr: usize = @intCast(addr);
            phys_bitmap.markFree(phys_addr);
        }
    }

    vga.writeStringAt(21, 0, "Bitmap init complete!", 15, 0);
}
