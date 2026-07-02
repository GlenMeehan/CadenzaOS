// src/kernel/scheduler.zig
const std = @import("std");
const config = @import("config.zig");
const bm = @import("bitmap.zig");
const memory = @import("memory.zig");
const vga = @import("vga.zig");
const conv = @import("convert.zig");

pub const TaskState = enum {
    Ready,
    Running,
    Suspended,
    Dead,
};

/// Represents the layout of registers on the stack during a cooperative context switch.
pub const TaskContext = packed struct {
    r15: u64, r14: u64, r13: u64, r12: u64,
    r11: u64, r10: u64, r9:  u64, r8:  u64,
    rbp: u64, rdi: u64, rsi: u64, rdx: u64,
    rcx: u64, rbx: u64, rax: u64,
    rip: u64,
};

/// NEW: Represents the exact layout of registers on the stack during a preemptive context switch.
/// This matches the x86_64 hardware interrupt and iretq expectations perfectly.
pub const InterruptContext = packed struct {
    // 1. Manually-pushed registers, in actual low-to-high memory order
    //    (i.e., reverse of push order — last pushed = lowest address = first field)
    rax: u64, rbx: u64, rcx: u64, rdx: u64,
    rsi: u64, rdi: u64, rbp: u64,
    r8:  u64, r9:  u64, r10: u64, r11: u64,
    r12: u64, r13: u64, r14: u64, r15: u64,
    // 2. Hardware Interrupt Frame pushed automatically by the CPU (unchanged — already correct)
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

pub const Task = struct {
    id: usize,
    stack_ptr: usize, // Points to the top of the stack where a TaskContext is saved
    state: TaskState,
    wake_tick: u64 = 0,
    stack_mem: ?[]u8 = null,
    code_mem: ?[]u8 = null,
    code_phys: usize = 0,
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

        // ---- FIX 1: Upgrade from TaskContext to InterruptContext ----
        var initial_sp = stack_top - @sizeOf(InterruptContext);
        initial_sp = (initial_sp & ~@as(usize, 15)); // 16-byte alignment enforce

        // ---- FIX 2: Cast pointer to the correct InterruptContext structure ----
        const context_ptr = @as(*InterruptContext, @ptrFromInt(initial_sp));

        // Clear all register fields cleanly to prepare for first context load
        inline for (std.meta.fields(InterruptContext)) |field| {
            @field(context_ptr, field.name) = 0;
        }

        // Direct execution to our target function pointer when switched into
        context_ptr.rip = @intFromPtr(entry_point);

        // ---- CRITICAL INTEL LONG MODE ARCHITECTURE FRAME SETUP ----
        context_ptr.cs = 0x18;         // Your kernel's Code Segment Selector (0x18)
        context_ptr.rflags = 0x202;    // 0x200 (Interrupts Enabled flag) + 0x02 (Reserved bit)

        // Point RSP directly to the context block itself so it has a perfectly
        // aligned, safe, writable zone within the allocated 4KB buffer.
        context_ptr.rsp = initial_sp;
        context_ptr.ss = 0x10;         // Your kernel's Data/Stack Segment Selector (0x20)
        // -----------------------------------------------------------

        self.tasks[slot] = Task{
            .id = id,
            .stack_ptr = initial_sp,
            .state = .Ready,
            // Ensure any extra fields required by your Task struct are here
            // (like .wake_tick = 0, .stack_mem = stack_buf if required)
        };
    }

    /// Dynamically allocates a stack and registers a new task into the first free slot.
    /// Returns the slot index on success, or an error if no slots are available.
    pub fn registerDynamicTask(
        self: *Scheduler,
        entry_point: *const fn() callconv(.c) void,
        code_mem: ?[]u8,
        code_phys: usize,
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

        // 3. Allocate stack using frame allocator (avoids heap fragmentation)
        const phys_addr = bm.allocContiguous(2) orelse return error.OutOfMemory;
        const virt_addr = memory.physToVirt(phys_addr);
        const stack_buf = @as([*]u8, @ptrFromInt(virt_addr))[0..bm.PAGE_SIZE * 2];

        // 4. Set up the initial context using InterruptContext natively
        const stack_top = @intFromPtr(stack_buf.ptr) + stack_buf.len;
        var initial_sp = stack_top - @sizeOf(InterruptContext);
        initial_sp = (initial_sp & ~@as(usize, 15));

        const context_ptr = @as(*InterruptContext, @ptrFromInt(initial_sp));
        inline for (std.meta.fields(InterruptContext)) |field| {
            @field(context_ptr, field.name) = 0;
        }

        // Populate the hardware frame fields exactly how iretq expects them
        context_ptr.rip = @intFromPtr(entry_point);
        context_ptr.cs = 0x18;         // Kernel Code Segment
        context_ptr.rflags = 0x202;     // Interrupts Enabled Flag
        // Point RSP directly to the context block itself so it has a perfectly
        // aligned, safe, writable zone within the allocated 4KB buffer.
        context_ptr.rsp = initial_sp;
        context_ptr.ss = 0x10;         // Kernel Data Segment

        // 5. Register the task
        self.tasks[slot.?] = Task{
            .id = id,
            .stack_ptr = initial_sp,
            .state = .Ready,
            .wake_tick = 0,
            .stack_mem = stack_buf,
            .code_mem = code_mem,
            .code_phys = code_phys,
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

        // 2. Strict Round-Robin tracking allowing Ready or Running tasks to schedule
        var next_idx = (self.current_task_idx + 1) % self.tasks.len;
        while (next_idx != self.current_task_idx) {
            if (self.tasks[next_idx]) |t| {
                // FIX: Accept .Ready OR .Running tasks so the shell (Slot 0) isn't skipped
                if (t.state == .Ready or t.state == .Running) {
                    return next_idx;
                }
            }
            next_idx = (next_idx + 1) % self.tasks.len;
        }

        // 3. Fallback: If nothing else is available, stay on current task
        if (self.tasks[self.current_task_idx]) |curr| {
            if (curr.state == .Running or curr.state == .Ready) return self.current_task_idx;
        }

        // 4. Ultimate Architectural Fallback: Return to the Shell (Slot 0)
        return 0;
    }

    /// Initiates a cooperative context switch.
    /// Initiates a cooperative context switch. (DISABLED FOR NOW)
    pub fn yield(self: *Scheduler) void {
        // Completely neutralized to focus purely on preemption
        _ = self;
    }

    /// Specialized entry point for the assembly IRQ0 stub.
    /// Receives the old stack pointer, switches tasks if preemption is allowed,
    /// and returns the stack pointer of the task that should execute next.
    pub export fn preempt_handler(interrupted_stack_ptr: usize) usize {
        if (!manager.yield_enabled) return interrupted_stack_ptr;

        // Cleanup dead tasks
        for (0..manager.tasks.len) |i| {
            if (manager.tasks[i]) |t| {
                if (t.state == .Dead) {
                    if (t.stack_mem) |mem_slice| {
                        const phys = memory.virtToPhys(@intFromPtr(mem_slice.ptr));
                        bm.freeContiguous(phys, 2);
                    }
                    if (t.code_mem) |code_slice| {
                        const phys = @intFromPtr(code_slice.ptr); // already physical — cmd_spawn never applied physToVirt here
                        const frame_count = (code_slice.len + bm.PAGE_SIZE - 1) / bm.PAGE_SIZE;
                        bm.freeContiguous(phys, frame_count);
                    }
                    manager.tasks[i] = null;
                }
            }
        }

        const next_idx = manager.pickNextTask();
        if (next_idx == manager.current_task_idx) return interrupted_stack_ptr;

        const current_old = manager.current_task_idx;

        // ---- SANITIZE SHELL SEGMENTS ON FIRST INTERRUPT ----
        // If we are interrupting the shell (Task 0) for the first time,
        // force its stack segment out of null state (0x0000) into a valid selector (0x20)
        if (current_old == 0 and interrupted_stack_ptr != 0) {
            const frame = @as(*InterruptContext, @ptrFromInt(interrupted_stack_ptr));
            if (frame.ss == 0) {
                frame.ss = 0x10;
                frame.cs = 0x18; // Ensure it matches your working CS exactly
            }
        }
        // ----------------------------------------------------

        if (manager.tasks[current_old]) |*curr| {
            if (curr.state == .Running) curr.state = .Ready;
        }

        // Save old stack pointer raw
        manager.tasks[current_old].?.stack_ptr = interrupted_stack_ptr;

        // Switch to new task
        manager.current_task_idx = next_idx;
        manager.tasks[next_idx].?.state = .Running;

        return manager.tasks[next_idx].?.stack_ptr;
    }

    /// Entry point for the int 0x80 "task exit" trap.
    /// Marks the currently running task as Dead and immediately switches away —
    /// the dying task's stack frame is discarded and never resumed.
    /// Actual frame cleanup (stack_mem/code_mem) happens later, in
    /// preempt_handler's existing cleanup pass on the next timer tick.
    pub export fn syscall_handler(stack_ptr: usize) usize {
        const ctx = @as(*InterruptContext, @ptrFromInt(stack_ptr));

        switch (ctx.rax) {
            0 => { // EXIT
                if (manager.tasks[manager.current_task_idx]) |*t| {
                    t.state = .Dead;
                }
                const next_idx = manager.pickNextTask();
                manager.current_task_idx = next_idx;
                manager.tasks[next_idx].?.state = .Running;
                return manager.tasks[next_idx].?.stack_ptr;
            },
            1 => { // PRINT_STRING
                const phys_ptr = blk: {
                    if (manager.tasks[manager.current_task_idx]) |t| {
                        if (t.code_phys != 0) {
                            // rdi is a link-time offset from binary base (0x0)
                            // translate to real physical address using stored frame base
                            break :blk t.code_phys + ctx.rdi;
                        }
                    }
                    // Static task or unknown — treat rdi as already physical
                    break :blk ctx.rdi;
                };
                const virt_ptr = memory.physToVirt(phys_ptr);
                const ptr: [*]const u8 = @ptrFromInt(virt_ptr);
                const len: usize = ctx.rsi;
                vga.writeString(ptr[0..len], 15, 0);
                return stack_ptr;
            },
            else => {
                return stack_ptr; // unknown syscall — no-op
            },
        }
    }

};

// -----------------------------------------------------------------------------
//  GLOBAL MANAGER INSTANCE
// -----------------------------------------------------------------------------
pub var manager: Scheduler = undefined;


