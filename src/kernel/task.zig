// src/kernel/task.zig

const std = @import("std");
const config = @import("config.zig");

/// The assembly function that performs the actual context switch.
/// rdi = address of old_rsp (to save current stack pointer)
/// rsi = value of new_rsp (to load next stack pointer)
pub extern fn switch_tasks(old_rsp: *usize, new_rsp: usize) void;

const MAX_TASKS = config.scheduler.max_tasks;
pub var preemption_requested: bool = false;

pub const TaskState = enum {
    Ready,      // Waiting to be picked by the scheduler
    Running,    // Currently executing on the CPU
    Blocked,    // Waiting for an event (I/O, timer)
    Dead,       // Finished execution, needs cleanup
};

/// Represents the CPU register state saved on a task's stack.
pub const RegisterContext = struct {
    r15: u64, r14: u64, r13: u64, r12: u64,
    r11: u64, r10: u64, r9: u64, r8: u64,
    rbp: u64, rdi: u64, rsi: u64, rdx: u64,
    rcx: u64, rbx: u64, rax: u64,
    rip: u64, // The instruction pointer the task will resume at
};

pub const YieldControl = enum {
    Manual,
    Auto,
};

pub const Task = struct {
    id: u32,
    stack_ptr: usize,   // The current top of the stack (holding the context)
    state: TaskState,
    stack_mem: []u8,    // The allocated memory for the stack
    wake_tick: u64,

    /// Initializes a brand new task with its own allocated stack.
    /// Pre-loads the stack with a RegisterContext so switch_tasks can "resume" it.
    pub fn init(id: u32, allocator: std.mem.Allocator, entry_point: usize) !Task {
        const stack = try allocator.alloc(u8, config.scheduler.default_stack_size);
        const stack_top = @intFromPtr(stack.ptr) + stack.len;

        // Align the stack to 16-bytes as per x86_64 ABI
        var initial_sp = stack_top - @sizeOf(RegisterContext);
        initial_sp = (initial_sp & ~@as(usize, 15));

        const reg_ptr = @as(*RegisterContext, @ptrFromInt(initial_sp));

        // Clear all registers to avoid leaking data from previous tasks
        inline for (std.meta.fields(RegisterContext)) |field| {
            @field(reg_ptr, field.name) = 0;
        }

        // Set the starting point for the task
        reg_ptr.rip = entry_point;

        return Task{
            .id = id,
            .stack_ptr = initial_sp,
            .state = .Ready,
            .stack_mem = stack,
            .wake_tick = 0,
        };
    }
};

pub const TaskManager = struct {
    tasks: [8]?Task,
    current_task_idx: usize,
    count: usize,
    allocator: std.mem.Allocator,
    ticks: u64 = 0,
    yield_enabled: bool = false,
    yield_control: YieldControl = .Manual,
    preemption_lock: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) TaskManager {
        return .{
            .tasks = .{null} ** MAX_TASKS,
            .current_task_idx = 0,
            .count = 0,
            .allocator = allocator,
        };
    }

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

    pub fn yield(self: *TaskManager) void {
        // 1. CLEANUP PHASE (Remains the same)
        for (0..MAX_TASKS) |i| {
            if (i == self.current_task_idx) continue;
            if (self.tasks[i]) |t| {
                if (t.state == .Dead) {
                    self.allocator.free(t.stack_mem);
                    self.tasks[i] = null;
                    self.count -= 1;
                }
            }
        }

        if (self.count < 2) return;

        const old_idx = self.current_task_idx;
        var next_idx = (old_idx + 1) % MAX_TASKS;

        // 2. SELECTION PHASE (Refined)
        // We loop until we find a task or realize we've checked everyone.
        var search_count: usize = 0;
        while (search_count < MAX_TASKS) : (search_count += 1) {
            if (self.tasks[next_idx]) |*t| {
                if (t.state != .Dead) {
                    if (t.state == .Blocked) {
                        // Check if the alarm clock went off
                        if (self.ticks >= t.wake_tick) {
                            t.state = .Ready;
                            break; // Found our task!
                        }
                    } else if (t.state == .Ready or t.state == .Running) {
                        // Current task or a waiting task is fine
                        break;
                    }
                }
            }
            next_idx = (next_idx + 1) % MAX_TASKS;
        }

        // If we circled back to ourselves and we aren't Ready/Running, stop.
        if (next_idx == old_idx and self.tasks[old_idx].?.state == .Blocked) return;

        // If the task we found is the same one already running, no context switch needed!
        if (next_idx == old_idx) return;

        // 3. TRANSITION PHASE
        // Save the old state safely
        if (self.tasks[old_idx]) |*t| {
            if (t.state == .Running) t.state = .Ready;
        }

        self.current_task_idx = next_idx;
        self.tasks[next_idx].?.state = .Running;

        // 4. EXECUTION PHASE
        switch_tasks(
            &self.tasks[old_idx].?.stack_ptr,
            self.tasks[next_idx].?.stack_ptr
        );
    }


    pub fn lock_preemption(self: *TaskManager) void {
        self.preemption_lock += 1;
    }

    pub fn unlock_preemption(self: *TaskManager) void {
        if (self.preemption_lock > 0) self.preemption_lock -= 1;
    }
};

// --- Global Scheduler State ---
pub var manager: TaskManager = undefined;

/// Global helper for tasks to voluntarily give up their time slice.
pub fn yield() void {
    manager.yield();
}

/// Marks the current task as Dead and yields the CPU so it can be cleaned up.
pub fn exit() void {
    if (manager.tasks[manager.current_task_idx]) |*t| {
        t.state = .Dead;
    }
    yield();
}

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

/// The entry point for the Shell to dynamically create a new managed task.
pub fn spawn(entry_point: usize, allocator: std.mem.Allocator) !usize {
    const id = @as(u32, @intCast(manager.count));
    const new_task = try Task.init(id, allocator, entry_point);
    return try manager.addTask(new_task);
}

/// Puts the current task to sleep for a specified number of milliseconds.
pub fn sleep(ms: u64) void {
    // 1. Calculate how many ticks to wait
    // (Assuming 100Hz timer, so 1 tick = 10ms. Adjust based on your config!)
    const ticks_to_wait = ms / 10;

    if (manager.tasks[manager.current_task_idx]) |*t| {
        t.wake_tick = manager.ticks + ticks_to_wait;
        t.state = .Blocked;
    }

    // 2. Immediately give up the CPU so other tasks can run
    yield();
}
