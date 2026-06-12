// src/kernel/irupts.zig
//
// Hardware interrupt handlers for:
//   • IRQ0  — PIT timer
//   • IRQ1  — PS/2 keyboard
//   • IRQ12 — PS/2 mouse
//
// All handlers:
//   • Perform minimal work
//   • Update state / forward to subsystem
//   • Send EOI to PIC (master or master+slave)

const vga = @import("vga.zig");
const io = @import("port_io.zig");
const conv = @import("convert.zig");
const keyboard = @import("inputs/keyboard.zig");
const task = @import("task.zig");
const config = @import("config.zig");
const scheduler = @import("scheduler.zig");

pub var ticks: u64 = 0;

// -----------------------------------------------------------------------------
//  IRQ0 — TIMER
// -----------------------------------------------------------------------------

pub export fn irq0_handler() callconv(.c) void {
    // 1. Increment the local, standalone global clock instead of task.manager
    ticks += 1;
    scheduler.manager.ticks = ticks;  // ← keep scheduler in sync
    const current_ticks = ticks;

    // 2. UPTIME DISPLAY: Refresh once per second (every 100 ticks)
    if (current_ticks % 100 == 0) {
        const total_seconds = current_ticks / 100;
        const minutes = @as(u32, @intCast(total_seconds / 60));
        const seconds = @as(u32, @intCast(total_seconds % 60));

        var m_buf: [16]u8 = undefined;
        var s_buf: [16]u8 = undefined;

        const m_str = conv.u32ToStr(&m_buf, minutes);
        const s_str = conv.u32ToStr(&s_buf, seconds);

        const row: u16 = 0;
        const col_start: u16 = 60;

        vga.writeStringAt(row, col_start, "Uptime: ", 0x07, 0);

        // Draw minutes
        vga.writeStringAt(row, col_start + 8, m_str, 0x0E, 0);
        const m_len = @as(u16, @intCast(m_str.len));
        vga.writeStringAt(row, col_start + 8 + m_len, "m ", 0x07, 0);

        // Draw seconds
        const s_pos = col_start + 8 + m_len + 2;
        vga.writeStringAt(row, s_pos, s_str, 0x0E, 0);
        const s_len = @as(u16, @intCast(s_str.len));
        vga.writeStringAt(row, s_pos + s_len, "s ", 0x07, 0);
    }

// ---- NEW PREEMPTIVE HANDOFF ENGINE ----
    // 1. Manually check and wake up tasks whose sleep timers have expired
    inline for (&scheduler.manager.tasks) |*maybe_task| {
        if (maybe_task.*) |*t| {
            if (t.state == .Suspended and ticks >= t.wake_tick) {
                t.state = .Ready;
            }
        }
    }

    // 2. If preemption is globally unmasked, force an implicit context yield
    if (scheduler.manager.yield_enabled) {
        scheduler.manager.yield();
    }
    // ----------------------------------------

    // 3. EOI: Tell the hardware we processed the interrupt
    io.outb(0x20, 0x20);
}

// -----------------------------------------------------------------------------
//  IRQ1 — KEYBOARD
// -----------------------------------------------------------------------------

pub export fn irq1_handler() callconv(.c) void {
    // 1. Read the scancode from port 0x60
    const scancode = io.inb(0x60);
    keyboard.handleScancode(scancode);

    // 2. Send EOI to master PIC
    io.outb(0x20, 0x20);

    // 3. REACTIVE YIELD LEFT-OVER: COMMENTED OUT COMPLETELY
    // if (task.manager.tasks[0]) |*shell| {
    //     if (shell.state == .Blocked and shell.wake_tick == 0) {
    //         shell.state = .Ready;
    //     }
    // }
}

// -----------------------------------------------------------------------------
//  IRQ12 — MOUSE
// -----------------------------------------------------------------------------

var mouse_index: u8 = 0;
var mouse_packet: [3]u8 = .{0, 0, 0};
var count: u8 = 0;

//Initiatlise PIT - this function is called in kernel.zig/kmain in the IDT / PIC / MOUSE / INTERRUPTS section
//Call after PIT and mouse initialisation but before sti
pub fn init_pit(frequency: u32) void {
    // The oscillator runs at 1.193182 MHz
    const divisor = @as(u16, @intCast(1193182 / frequency));

    // 0x43 is the Command Register
    // 0x36 = 00 (Channel 0) 11 (Access lobyte/hibyte) 011 (Square wave) 0 (Binary)
    io.outb(0x43, 0x36);

    // 0x40 is Channel 0 Data Port
    io.outb(0x40, @as(u8, @intCast(divisor & 0xFF)));        // Low byte
    io.outb(0x40, @as(u8, @intCast((divisor >> 8) & 0xFF))); // High byte
}


pub export fn irq12_handler() callconv(.c) void {
    // Debug counter
    count += 1;
    var buf0: [18]u8 = undefined;
    vga.writeStringAt(6, 53, conv.toHex(u8, count, &buf0), 15, 0);

    // Read next byte of PS/2 mouse packet
    const byte = io.inb(0x60);
    mouse_packet[mouse_index] = byte;
    mouse_index += 1;

    // Full 3‑byte packet received?
    if (mouse_index == 3) {
        mouse_index = 0;

        const raw_dx = mouse_packet[1];
        const raw_dy = mouse_packet[2];

        // Convert to signed deltas
        const dx = @as(i8, @bitCast(raw_dx));
        const dy = @as(i8, @bitCast(raw_dy));

        const dx_u8: u8 = @bitCast(dx);
        const dy_u8: u8 = @bitCast(dy);

        var buf1: [18]u8 = undefined;
        var buf2: [18]u8 = undefined;

        // Debug output
        vga.writeStringAt(4, 53, "Mouse dx", 15, 0);
        vga.writeStringAt(4, 63, conv.toHex(u8, dx_u8, &buf1), 15, 0);

        vga.writeStringAt(5, 53, "Mouse dy", 15, 0);
        vga.writeStringAt(5, 63, conv.toHex(u8, dy_u8, &buf2), 15, 0);
    }

    // EOI: slave PIC first, then master PIC
    io.outb(0xA0, 0x20); // slave
    io.outb(0x20, 0x20); // master
}


// Sleep for a number of ticks.
pub fn sleep(ticks_to_wait: u64) void {
    const start_tick = ticks; // Define it here!
    while (ticks - start_tick < ticks_to_wait) {
        asm volatile ("hlt");
    }
}
