// src/kernel/scheduler.zig
const std = @import("std");
const config = @import("config.zig");

pub const TaskState = enum {
    Ready,
    Running,
    Suspended,
    Dead,
};

/// Represents the exact layout of registers on the stack during a context switch.
/// This matches the x86_64 calling and interrupt convention state.
pub const TaskContext = packed struct {
    // These match the 15 registers pushed/popped manually by switch_tasks
    r15: u64, r14: u64, r13: u64, r12: u64,
    r11: u64, r10: u64, r9:  u64, r8:  u64,
    rbp: u64, rdi: u64, rsi: u64, rdx: u64,
    rcx: u64, rbx: u64, rax: u64,

    // Pushed automatically onto the stack by the CPU 'call' instruction,
    // or manually fabricated for starting tasks (Task A & B)
    rip: u64,
};

pub const Task = struct {
    id: usize,
    stack_ptr: usize, // Points to the top of the stack where a TaskContext is saved
    state: TaskState,
    wake_tick: u64 = 0,
    stack_mem: ?[]u8 = null,
};

pub const Scheduler = struct {
    // 1. ALL FIELDS MUST BE AT THE TOP
    tasks: [config.scheduler.max_tasks]?Task,
    current_task_idx: usize,
    yield_enabled: bool,
    ticks: u64 = 0,
    allocator: ?std.mem.Allocator = null,

    // 2. DECLARATIONS & FUNCTIONS MUST GO AFTER ALL FIELDS
    extern fn switch_tasks(old_stack: *usize, new_stack: usize) callconv(.c) void;

    /// Set up an empty task timeline
    pub fn init(allocator: std.mem.Allocator) Scheduler {
        return Scheduler{
            .tasks = [_]?Task{null} ** config.scheduler.max_tasks,
            .current_task_idx = 0,
            .yield_enabled = false,
            .allocator = allocator,
        };
    }

    /// Takes the currently executing execution thread and registers it into a task slot.
    /// This is perfect for turning kmain/shell into a managed task without messing with stacks.
    pub fn registerCurrentThreadAsTask(self: *Scheduler, slot: usize, id: usize) void {
        self.tasks[slot] = Task{
            .id = id,
            .stack_ptr = 0, // Will be captured accurately on its very first yield() call
            .state = .Running,
        };
    }

    /// NEW: Manually primes a static memory slice with an initial execution frame.
    /// This allows us to load external tasks (like taskA_main) into the timeline.
    pub fn registerStaticTask(
        self: *Scheduler,
        slot: usize,
        id: usize,
        entry_point: *const fn() callconv(.c) void,
                              stack_buf: []u8
    ) void {
        const stack_top = @intFromPtr(stack_buf.ptr) + stack_buf.len;

        // Position our context tracking record precisely at the top of the buffer
        var initial_sp = stack_top - @sizeOf(TaskContext);
        initial_sp = (initial_sp & ~@as(usize, 15)); // 16-byte alignment enforce

        const context_ptr = @as(*TaskContext, @ptrFromInt(initial_sp));

        // Clear all register fields cleanly to prepare for first context load
        inline for (std.meta.fields(TaskContext)) |field| {
            @field(context_ptr, field.name) = 0;
        }

        // Direct execution to our target function pointer when switched into
        context_ptr.rip = @intFromPtr(entry_point);

        self.tasks[slot] = Task{
            .id = id,
            .stack_ptr = initial_sp,
            .state = .Ready,
        };
    }

    /// Dynamically allocates a stack and registers a new task into the first free slot.
    /// Returns the slot index on success, or an error if no slots are available.
    pub fn registerDynamicTask(
        self: *Scheduler,
        entry_point: *const fn() callconv(.c) void,
                               allocator: std.mem.Allocator,
    ) !usize {
        // 1. Find a free slot
        var slot: ?usize = null;
        for (0..self.tasks.len) |i| {
            if (self.tasks[i] == null) {
                slot = i;
                break;
            }
        }
        if (slot == null) return error.NoTaskSlotsAvailable;

        // 2. Generate a unique ID automatically
        const id = self.nextId();

        // 3. Allocate stack memory
        const stack_buf = try allocator.alloc(u8, 4096);

        // 4. Set up the initial context
        const stack_top = @intFromPtr(stack_buf.ptr) + stack_buf.len;
        var initial_sp = stack_top - @sizeOf(TaskContext);
        initial_sp = (initial_sp & ~@as(usize, 15));

        const context_ptr = @as(*TaskContext, @ptrFromInt(initial_sp));
        inline for (std.meta.fields(TaskContext)) |field| {
            @field(context_ptr, field.name) = 0;
        }
        context_ptr.rip = @intFromPtr(entry_point);

        // 5. Register the task
        self.tasks[slot.?] = Task{
            .id = id,
            .stack_ptr = initial_sp,
            .state = .Ready,
            .wake_tick = 0,
            .stack_mem = stack_buf,
        };

        return slot.?;
    }

    /// Returns the next available unique task ID.
    /// Scans all slots for the highest current ID and returns one higher.
    /// IDs are never reused — gaps appear when tasks die but that is safe and simple.
    pub fn nextId(self: *Scheduler) usize {
        var max_id: usize = 0;
        for (self.tasks) |maybe_task| {
            if (maybe_task) |t| {
                if (t.id > max_id) max_id = t.id;
            }
        }
        return max_id + 1;
    }

    /// Returns a pointer to the task with the given ID, or null if not found.
    pub fn findTaskById(self: *Scheduler, id: usize) ?*Task {
        for (&self.tasks) |*maybe_task| {
            if (maybe_task.*) |*t| {
                if (t.id == id) return t;
            }
        }
        return null;
    }

    /// The core time-allocation logic.
    /// Cyclically loops through the array to find the next active task slot.
    pub fn pickNextTask(self: *Scheduler) usize {
        // 1. Wake up any suspended tasks whose timer thresholds have passed
        for (&self.tasks) |*maybe_task| {
            if (maybe_task.*) |*t| {
                if (t.state == .Suspended and self.ticks >= t.wake_tick) {
                    t.state = .Ready;
                }
            }
        }

        // 2. Strict Round-Robin tracking using direct array optional checks
        var next_idx = (self.current_task_idx + 1) % self.tasks.len;
        while (next_idx != self.current_task_idx) {
            if (self.tasks[next_idx]) |t| {
                // Only switch to a task that is explicitly ready to execute
                if (t.state == .Ready) {
                    return next_idx;
                }
            }
            next_idx = (next_idx + 1) % self.tasks.len;
        }

        // 3. Fallback: If current task is still running and nothing else is ready, stay on it.
        if (self.tasks[self.current_task_idx]) |curr| {
            if (curr.state == .Running) return self.current_task_idx;
        }

        // 4. Absolute Fallback: Look for the Idle Task (traditionally Slot 1)
        if (self.tasks[1] != null) return 1;

        return 0;
    }

    /// Initiates a cooperative context switch.
    pub fn yield(self: *Scheduler) void {
        if (!self.yield_enabled) return;

        // 1. Cleanup any dead tasks cleanly
        for (0..self.tasks.len) |i| {
            if (i == self.current_task_idx) continue;
            if (self.tasks[i]) |t| {
                if (t.state == .Dead) {
                    if (t.stack_mem) |mem| {
                        if (self.allocator) |alloc| {
                            alloc.free(mem);
                        }
                    }
                    self.tasks[i] = null;
                }
            }
        }

        // 2. Determine who runs next
        const next_idx = self.pickNextTask();
        if (next_idx == self.current_task_idx) return;

        const current_old = self.current_task_idx;

        // 3. FIX: Mutate state via direct array access, not stack copy un-wrapping!
        if (self.tasks[current_old] != null) {
            if (self.tasks[current_old].?.state == .Running) {
                self.tasks[current_old].?.state = .Ready;
            }
        }

        self.current_task_idx = next_idx;

        if (self.tasks[next_idx] != null) {
            self.tasks[next_idx].?.state = .Running;
        }

        // 4. Fire assembly task switch safely
        switch_tasks(&self.tasks[current_old].?.stack_ptr, self.tasks[next_idx].?.stack_ptr);
    }
};

// -----------------------------------------------------------------------------
//  GLOBAL MANAGER INSTANCE
// -----------------------------------------------------------------------------
pub var manager: Scheduler = undefined;
