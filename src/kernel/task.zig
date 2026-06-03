// src/kernel/task.zig

const std = @import("std");
const config = @import("config.zig");
const scheduler = @import("scheduler.zig");

pub fn taskA_main() callconv(.c) void {
    asm volatile ("sti");
    const vga_ptr = @as([*]volatile u16, @ptrFromInt(0xB8000));
    var run_count: u32 = 0;

    while (true) {
        run_count += 1;
        draw_counter(vga_ptr, 1900, run_count);

        // Flash 'A' once every half second
        vga_ptr[1919] = (@as(u16, 0x0A) << 8) | 'A';
        sleep(500); // <--- REPLACED THE SPIN LOOP

        vga_ptr[1919] = (@as(u16, 0x07) << 8) | ' ';
        sleep(500); // <--- REPLACED THE SPIN LOOP

        scheduler.manager.yield();
    }
}

pub fn taskB_main() callconv(.c) void {
    asm volatile ("sti");
    const vga_ptr = @as([*]volatile u16, @ptrFromInt(0xB8000));
    var run_count: u32 = 0;

    while (true) {
        run_count += 1;
        draw_counter(vga_ptr, 1980, run_count);

        // Flash 'B' 4 times a second (250ms on, 250ms off)
        vga_ptr[1999] = (@as(u16, 0x09) << 8) | 'B';
        sleep(250);

        vga_ptr[1999] = (@as(u16, 0x07) << 8) | ' ';
        sleep(250);
    }
}

fn draw_counter(vga: [*]volatile u16, pos: usize, val: u32) void {
    const hex = "0123456789ABCDEF";
    var v = val;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const char = hex[v & 0xF];
        vga[pos + (3 - i)] = (@as(u16, 0x0E) << 8) | char;
        v >>= 4;
    }
}

/// Puts the currently executing task to sleep for a specified number of milliseconds.
/// Calculates required ticks dynamically based on the configured timer hardware frequency.
pub fn sleep(ms: u64) void {
    const frequency = config.timer.frequency_hz;
    const ticks_to_wait = (ms * frequency) / 1000;
    const wake_at = scheduler.manager.ticks + ticks_to_wait;

    // Set state to suspended
    const my_idx = scheduler.manager.current_task_idx;
    if (scheduler.manager.tasks[my_idx]) |*t| {
        t.wake_tick = wake_at;
        t.state = .Suspended;
    }

    // Yield to let other tasks run if available
    scheduler.manager.yield();

    // Busy-wait until wake time in case yield returned immediately
    while (scheduler.manager.ticks < wake_at) {
        asm volatile ("hlt");
    }

    // Mark ourselves Ready again
    if (scheduler.manager.tasks[my_idx]) |*t| {
        if (t.state == .Suspended) t.state = .Ready;
    }
}
