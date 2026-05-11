//src/kernel/task.zig

const std = @import("std");

/// The assembly function that performs the actual context switch.
/// rdi = address of old_rsp (to save current stack pointer)
/// rsi = value of new_rsp (to load next stack pointer)
pub extern fn switch_tasks(old_rsp: *usize, new_rsp: usize) void;

const MAX_TASKS = 8;
pub var preempt_requested: bool = false;

pub const TaskState = enum {
    Ready,      // Waiting to be picked by the scheduler
    Running,    // Currently executing on the CPU
    Blocked,    // Waiting for an event (I/O, timer)
    Dead,       // Finished execution, needs cleanup
};

pub const RegisterContext = struct {
    r15: u64, r14: u64, r13: u64, r12: u64,
    r11: u64, r10: u64, r9: u64, r8: u64,
    rbp: u64, rdi: u64, rsi: u64, rdx: u64,
    rcx: u64, rbx: u64, rax: u64,

    // This is what 'ret' in arch_util.s will jump to
    rip: u64,
};

pub const Task = struct {
    id: u32,
    stack_ptr: usize,   // The current top of the stack (holding the context)
    state: TaskState,
    stack_mem: []u8,    // The allocated memory for the stack

    /// Initializes a brand new task with its own allocated stack.
    pub fn init(id: u32, allocator: std.mem.Allocator, entry_point: usize) !Task {
        const stack = try allocator.alloc(u8, 4096);
        const stack_top = @intFromPtr(stack.ptr) + stack.len;

        var initial_sp = stack_top - @sizeOf(RegisterContext);
        initial_sp = (initial_sp & ~@as(usize, 15));

        const reg_ptr = @as(*RegisterContext, @ptrFromInt(initial_sp));

        // 1. Clear all registers
        inline for (std.meta.fields(RegisterContext)) |field| {
            @field(reg_ptr, field.name) = 0;
        }

        // 2. Set the entry point
        reg_ptr.rip = entry_point;

        return Task{
            .id = id,
            .stack_ptr = initial_sp,
            .state = .Ready,
            .stack_mem = stack,
        };
    }
};

pub const TaskManager = struct {
    tasks: [8]?Task,
    current_task_idx: usize,
    count: usize,
    yield_enabled: bool = false, // Start disabled!

    pub fn init() TaskManager {
        return .{
            .tasks = .{null} ** MAX_TASKS,
            .current_task_idx = 0,
            .count = 0,
        };
    }

    /// Finds a free slot and adds a task to the round-robin list.
    pub fn addTask(self: *TaskManager, task: Task) !usize {
        for (0..MAX_TASKS) |i| {
            if (self.tasks[i] == null) {
                self.tasks[i] = task;
                self.count += 1;
                return i;
            }
        }
        return error.NoTaskSlotsAvailable;
    }

    /// The Round-Robin Scheduler logic.
    /// Saves the current task's state and switches to the next available one.
    pub fn yield(self: *TaskManager) void {
        if (self.count < 2) return; // Nowhere to switch to

        const old_idx = self.current_task_idx;

        // Find the next task that exists and is not 'Dead'
        var next_idx = (old_idx + 1) % MAX_TASKS;
        while (self.tasks[next_idx] == null or self.tasks[next_idx].?.state == .Dead) {
            next_idx = (next_idx + 1) % MAX_TASKS;
            // If we looped back to the start and found nothing, just return
            if (next_idx == old_idx) return;
        }

        self.current_task_idx = next_idx;

        // Transition states
        if (self.tasks[old_idx]) |*t| {
            if (t.state == .Running) t.state = .Ready;
        }
        self.tasks[next_idx].?.state = .Running;

        // Perform the low-level stack swap
        // We pass the ADDRESS of the old stack_ptr so assembly can update it
        switch_tasks(
            &self.tasks[old_idx].?.stack_ptr,
            self.tasks[next_idx].?.stack_ptr
        );
    }
};

// --- Global Scheduler State ---
pub var manager: TaskManager = undefined;

/// The standard way for any task (including the Shell) to give up CPU time.
pub fn yield() void {
    manager.yield();
}


/// This is a simple function that our background task will run.
/// We mark it as 'pub' so shell.zig can see it, and 'callconv(.C)'
/// for standard stack behavior.
pub fn taskA_main() callconv(.c) void {

    // Force interrupts to be ENABLED as soon as this task starts
    asm volatile ("sti");
    const vga_ptr = @as([*]volatile u16, @ptrFromInt(0xB8000));
    var run_count: u32 = 0;

    while (true) {
        run_count += 1;

        // Draw a hex counter on the second row (index 150)
        draw_counter(vga_ptr, 150, run_count);

        var flashes: u8 = 0;
        while (flashes < 5) : (flashes += 1) {
            // Blinking 'A' at the top right corner (index 79)
            vga_ptr[79] = (@as(u16, 0x0A) << 8) | 'A';

            // Simple delay loop
            var i: u32 = 0;
            while (i < 2000000) : (i += 1) {
                asm volatile ("" : : : .{ .memory = true });
            }

            vga_ptr[79] = (@as(u16, 0x07) << 8) | ' ';
            i = 0;
            while (i < 2000000) : (i += 1) {
                asm volatile ("" : : : .{ .memory = true });
            }
        }

        // Use the new manager-based yield
        yield();
    }
}

/// Helper function used by taskA_main to render hex values to VGA memory.
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
