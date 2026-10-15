// src/kernel/scheduler.zig
//
// Cooperative and preemptive task scheduling support.
//
// Responsibilities:
//   • Track runnable and suspended tasks
//   • Maintain task execution contexts
//   • Perform task switching
//   • Manage scheduler timing state
//   • Allocate per-task execution stacks
//
const std = @import("std");
const config = @import("config.zig");
const bm = @import("bitmap.zig");
const memory = @import("memory.zig");
const vga = @import("vga.zig");
const conv = @import("convert.zig");
const serial = @import("drivers/serial.zig");

/// Physical scratch page used by the binary loader and task-launch
/// infrastructure.
const SCRATCH_PAGE_PHYS: usize = 0x7000;

/// Number of pages reserved for each task stack.
///
/// 8 pages = 32 KiB.
const TASK_STACK_PAGES: usize = 8;

/// Maximum number of command-line arguments passed to a task.
pub const MAX_ARGS: usize = 8;

/// Maximum combined argument storage size, including NUL terminators.
pub const MAX_ARG_BYTES: usize = 512;

/// Scheduler-visible task states.
pub const TaskState = enum {

    /// Ready to run and eligible for scheduling.
    Ready,

    /// Currently executing on the processor.
    Running,

    /// Temporarily blocked until a wake condition is satisfied.
    Suspended,

    /// Task has terminated and may be cleaned up.
    Dead,
};

/// Register layout preserved during a cooperative context switch.
///
/// The stack is arranged to match the expectations of the low-level
/// task-switch assembly routine.
pub const TaskContext = packed struct {
    r15: u64, r14: u64, r13: u64, r12: u64,
    r11: u64, r10: u64, r9:  u64, r8:  u64,
    rbp: u64, rdi: u64, rsi: u64, rdx: u64,
    rcx: u64, rbx: u64, rax: u64,
    rip: u64,
};

/// Complete processor state captured during an interrupt-driven
/// context switch.
///
/// Layout must match the combined state created by:
///   • The software interrupt entry stub
///   • The CPU-generated interrupt frame
///   • The iretq return path
pub const InterruptContext = packed struct {

    // Registers saved explicitly by the interrupt-entry assembly.
    //
    // Fields are ordered according to their final memory layout,
    // not their push order within the assembly handler.
    rax: u64, rbx: u64, rcx: u64, rdx: u64,
    rsi: u64, rdi: u64, rbp: u64,
    r8:  u64, r9:  u64, r10: u64, r11: u64,
    r12: u64, r13: u64, r14: u64, r15: u64,

    // Hardware interrupt frame pushed automatically by the CPU.
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

/// Scheduler-owned task record.
pub const Task = struct {

    /// Unique task identifier.
    id: usize,

    /// Saved stack pointer used during task restoration.
    stack_ptr: usize,

    /// Current scheduler state.
    state: TaskState,

    /// Tick value at which a suspended task becomes runnable.
    wake_tick: u64 = 0,

    /// Backing memory for the task stack.
    stack_mem: ?[]u8 = null,

    /// Backing memory for dynamically loaded task code.
    code_mem: ?[]u8 = null,

    /// Physical location of the loaded executable image.
    code_phys: usize = 0,
};

pub const Scheduler = struct {

    /// Scheduler task table.
    tasks: [config.scheduler.max_tasks]?Task,

    /// Index of the currently running task.
    current_task_idx: usize,

    /// Enables timer-driven task preemption.
    yield_enabled: bool,

    /// Global scheduler tick counter.
    ticks: u64 = 0,

    /// Allocator used for scheduler-owned resources.
    allocator: ?std.mem.Allocator = null,

    extern fn switch_tasks(old_stack: *usize, new_stack: usize) callconv(.c) void;

    /// Create an empty scheduler instance.
    ///
    /// No tasks are created automatically; task slots begin in an
    /// unused state and must be populated explicitly.
    pub fn init(allocator: std.mem.Allocator) Scheduler {
        return Scheduler{
            .tasks = [_]?Task{null} ** config.scheduler.max_tasks,
            .current_task_idx = 0,
            .yield_enabled = false,
            .allocator = allocator,
        };
    }

    /// Register the currently executing thread as a scheduler-managed
    /// task.
    ///
    /// This is primarily used during early boot to transition the
    /// initial kernel execution context into the scheduler's task
    /// model without performing an immediate context switch.
    pub fn registerCurrentThreadAsTask(self: *Scheduler, slot: usize, id: usize) void {

        const phys_addr =
        bm.allocContiguous(TASK_STACK_PAGES)
        orelse @panic("OutOfMemory allocating shell stack");

        const virt_addr = memory.physToVirt(phys_addr);

        const stack_buf =
        @as([*]u8, @ptrFromInt(virt_addr))
        [0 .. bm.PAGE_SIZE * TASK_STACK_PAGES];

        @memset(stack_buf, 0);

        self.tasks[slot] = Task{
            .id = id,

            // The initial stack pointer is captured when the task is
            // first preempted or explicitly switched.
            .stack_ptr = 0,

            .state = .Running,
            .wake_tick = 0,
            .stack_mem = stack_buf,
            .code_mem = null,
            .code_phys = 0,
        };
    }

    /// Create and register a new scheduler-managed task.
    ///
    /// A dedicated stack is allocated, an initial interrupt context is
    /// constructed, optional command-line arguments are copied onto the
    /// stack, and the task is inserted into the scheduler.
    ///
    /// Returns the assigned task-slot index on success.
    pub fn registerDynamicTask(
        self: *Scheduler,
        entry_point: *const fn () callconv(.c) void,
                               code_mem: ?[]u8,
                               code_phys: usize,
                               args: []const []const u8,
    ) !usize {

        // Validate argument limits before allocating any resources.
        if (args.len > MAX_ARGS) return error.TooManyArgs;

        var arg_bytes: usize = 0;
        for (args) |a| arg_bytes += a.len + 1;

        if (arg_bytes > MAX_ARG_BYTES) return error.ArgsTooLong;

        // Locate the first unused task slot.
        var slot: ?usize = null;

        for (0..self.tasks.len) |i| {
            if (self.tasks[i] == null) {
                slot = i;
                break;
            }
        }

        if (slot == null) return error.NoTaskSlotsAvailable;

        // Assign a unique task identifier.
        const id = self.nextId();

        // Allocate a dedicated task stack from contiguous physical
        // memory to avoid heap fragmentation.
        const phys_addr =
        bm.allocContiguous(TASK_STACK_PAGES)
        orelse return error.OutOfMemory;

        const virt_addr = memory.physToVirt(phys_addr);

        const stack_buf =
        @as([*]u8, @ptrFromInt(virt_addr))
        [0 .. bm.PAGE_SIZE * TASK_STACK_PAGES];

        // Clear any data left behind by previous users of the memory.
        @memset(stack_buf, 0);

        // ---------------------------------------------------------------------
        //  INITIAL STACK LAYOUT
        // ---------------------------------------------------------------------
        //
        // High addresses
        //
        //   [InterruptContext save area]
        //   [Argument strings]
        //   [argv array]
        //   [Synthetic return-address slot]
        //       ^
        //       Initial RSP
        //
        // Low addresses
        //
        // The interrupt save area must remain reserved because every
        // preemptive context switch stores processor state there.
        //

        const stack_top = @intFromPtr(stack_buf.ptr) + stack_buf.len;

        // Reserved interrupt-context save area.
        //
        // Must remain consistent with the destination used by the
        // preemption handler.
        const save_area =
        (stack_top - @sizeOf(InterruptContext))
        & ~@as(usize, 15);

        var cursor: usize = save_area;

        var str_addrs: [MAX_ARGS]usize = undefined;

        // Copy argument strings onto the task stack in reverse order
        // so their final addresses remain stable.
        var k: usize = args.len;

        while (k > 0) {
            k -= 1;

            const a = args[k];

            cursor -= a.len + 1;

            const dst = @as([*]u8, @ptrFromInt(cursor));

            @memcpy(dst[0..a.len], a);
            dst[a.len] = 0;

            str_addrs[k] = cursor;
        }

        // Construct the argv pointer array.
        cursor &= ~@as(usize, 15);

        cursor -= (args.len + 1) * @sizeOf(usize);
        cursor &= ~@as(usize, 15);

        const argv_addr = cursor;

        const argv = @as([*]usize, @ptrFromInt(argv_addr));

        for (0..args.len) |j| {
            argv[j] = str_addrs[j];
        }

        argv[args.len] = 0;

        // System V AMD64 ABI:
        //
        // Function entry expects RSP ≡ 8 (mod 16), matching the state
        // that would exist after a normal CALL instruction pushes a
        // return address.
        const entry_rsp = argv_addr - 8;

        // The initial saved context occupies the reserved interrupt
        // save area at the top of the stack.
        const initial_sp = save_area;

        const context_ptr = @as(*InterruptContext, @ptrFromInt(initial_sp));

        inline for (std.meta.fields(InterruptContext)) |field| {
            @field(context_ptr, field.name) = 0;
        }

        // Construct the machine state that will be restored when the
        // task executes for the first time.
        context_ptr.rip = @intFromPtr(entry_point);
        context_ptr.cs = 0x18;            // Kernel code segment
        context_ptr.rflags = 0x202;       // Interrupts enabled
        context_ptr.rsp = entry_rsp;
        context_ptr.ss = 0x10;            // Kernel data segment

        // Pass argc/argv using the standard x86_64 System V calling
        // convention.
        context_ptr.rdi = args.len;       // argc
        context_ptr.rsi = argv_addr;      // argv

        // Register the task with the scheduler.
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

    /// Generate the next scheduler task identifier.
    ///
    /// IDs are assigned monotonically and are never reused. Gaps may
    /// appear when tasks terminate, which is acceptable for the current
    /// scheduler design.
    pub fn nextId(self: *Scheduler) usize {
        var max_id: usize = 0;

        for (self.tasks) |maybe_task| {
            if (maybe_task) |t| {
                if (t.id > max_id) max_id = t.id;
            }
        }

        return max_id + 1;
    }

    /// Locate a task by its unique identifier.
    ///
    /// Returns a pointer to the task record, or null if no matching
    /// task exists.
    pub fn findTaskById(self: *Scheduler, id: usize) ?*Task {
        for (&self.tasks) |*maybe_task| {
            if (maybe_task.*) |*t| {
                if (t.id == id) return t;
            }
        }

        return null;
    }

    /// Select the next task to execute.
    ///
    /// The scheduler uses a simple round-robin policy, cycling through
    /// task slots and selecting the next runnable task.
    ///
    /// Suspended tasks whose wake time has expired are automatically
    /// returned to the Ready state before task selection occurs.
    pub fn pickNextTask(self: *Scheduler) usize {

        // Wake any sleeping tasks whose timeout has elapsed.
        for (&self.tasks) |*maybe_task| {
            if (maybe_task.*) |*t| {
                if (t.state == .Suspended and self.ticks >= t.wake_tick) {
                    t.state = .Ready;
                }
            }
        }

        // Search for the next runnable task using round-robin ordering.
        //
        // Both Ready and Running tasks are considered runnable.
        var next_idx = (self.current_task_idx + 1) % self.tasks.len;

        while (next_idx != self.current_task_idx) {
            if (self.tasks[next_idx]) |t| {
                if (t.state == .Ready or t.state == .Running) {
                    return next_idx;
                }
            }

            next_idx = (next_idx + 1) % self.tasks.len;
        }

        // Continue running the current task if it remains runnable.
        if (self.tasks[self.current_task_idx]) |curr| {
            if (curr.state == .Running or curr.state == .Ready) {
                return self.current_task_idx;
            }
        }

        // Final fallback: return to Task 0.
        return 0;
    }

    /// Timer-preemption entry point invoked by the IRQ0 assembly stub.
    ///
    /// Receives the interrupted task context, performs scheduling
    /// decisions, saves the outgoing context, and returns the stack
    /// pointer of the task that should execute next.
    pub export fn preempt_handler(interrupted_stack_ptr: usize) usize {

        // Scheduler preemption can be temporarily disabled during
        // critical boot and system-initialisation phases.
        if (!manager.yield_enabled) return interrupted_stack_ptr;

        // ---------------------------------------------------------------------
        //  TASK CLEANUP
        // ---------------------------------------------------------------------
        //
        // Reclaim resources owned by tasks that have terminated since
        // the previous scheduling cycle.
        //

        for (0..manager.tasks.len) |i| {
            if (manager.tasks[i]) |t| {
                if (t.state == .Dead) {

                    if (t.stack_mem) |mem_slice| {
                        const phys =
                            memory.virtToPhys(@intFromPtr(mem_slice.ptr));

                        bm.freeContiguous(
                            phys,
                            mem_slice.len / bm.PAGE_SIZE,
                        );
                    }

                    if (t.code_mem) |code_slice| {
                        const phys =
                            memory.virtToPhys(@intFromPtr(code_slice.ptr));

                        const frame_count =
                            (code_slice.len + bm.PAGE_SIZE - 1)
                            / bm.PAGE_SIZE;

                        bm.freeContiguous(phys, frame_count);
                    }

                    manager.tasks[i] = null;
                }
            }
        }

        const next_idx = manager.pickNextTask();

        // No task change required.
        if (next_idx == manager.current_task_idx) {
            return interrupted_stack_ptr;
        }

        const current_old = manager.current_task_idx;

        // ---------------------------------------------------------------------
        //  INITIAL SHELL CONTEXT NORMALISATION
        // ---------------------------------------------------------------------
        //
        // The bootstrap shell task may inherit segment values that are
        // unsuitable for long-term scheduling. Ensure the first saved
        // interrupt frame contains valid kernel selectors.
        //

        if (current_old == 0 and interrupted_stack_ptr != 0) {
            const frame =
                @as(*InterruptContext, @ptrFromInt(interrupted_stack_ptr));

            if (frame.ss == 0) {
                frame.ss = 0x10;
                frame.cs = 0x18;
            }
        }

        // ---------------------------------------------------------------------
        //  SAVE OUTGOING TASK CONTEXT
        // ---------------------------------------------------------------------

        if (manager.tasks[current_old]) |*curr| {

            if (curr.state == .Running) {
                curr.state = .Ready;
            }

            if (curr.stack_mem) |mem| {

                const ctx_size = @sizeOf(InterruptContext);

                const raw_dest =
                    @intFromPtr(mem.ptr) + mem.len - ctx_size;

                const dest_addr =
                    raw_dest & ~@as(usize, 15);

                const dest: [*]u8 =
                    @ptrFromInt(dest_addr);

                const src: [*]const u8 =
                    @ptrFromInt(interrupted_stack_ptr);

                // Preserve the complete interrupt frame so the task
                // can later resume exactly where it was interrupted.
                @memcpy(dest[0..ctx_size], src[0..ctx_size]);

                curr.stack_ptr = dest_addr;
            } else {

                // Fallback path used when no dedicated stack storage
                // is associated with the task.
                curr.stack_ptr = interrupted_stack_ptr;
            }
        }

        // ---------------------------------------------------------------------
        //  ACTIVATE NEXT TASK
        // ---------------------------------------------------------------------

        manager.current_task_idx = next_idx;
        manager.tasks[next_idx].?.state = .Running;

        // Scheduler trace output for task-switch debugging.
        var dbuf: [16]u8 = undefined;
        var dbuf2: [16]u8 = undefined;
        var dbuf3: [16]u8 = undefined;
        var line: [80]u8 = undefined;

        const msg = std.fmt.bufPrint(
            &line,
            "SW from={s} to={s} sp=0x{s}\n",
            .{
                conv.toHex(u64, current_old, &dbuf),
                conv.toHex(u64, next_idx, &dbuf2),
                conv.toHex(
                    u64,
                    manager.tasks[next_idx].?.stack_ptr,
                    &dbuf3,
                ),
            },
        ) catch "SW: fmt error\n";

        serial.writeString(msg);

        // Return the saved context of the task that should resume.
        return manager.tasks[next_idx].?.stack_ptr;
    }

    /// System-call dispatcher for interrupt vector 0x80.
    ///
    /// Receives a saved interrupt context, performs the requested
    /// service, updates registers as necessary, and returns the
    /// context that execution should resume with.
    ///
    /// Return values are communicated through the saved register state
    /// within the interrupt context, following normal calling
    /// convention expectations.
    pub export fn syscall_handler(stack_ptr: usize) usize {
        const ctx = @as(*InterruptContext, @ptrFromInt(stack_ptr));

        switch (ctx.rax) {

            // -----------------------------------------------------------------
            //  SYSCALL 0 - EXIT
            // -----------------------------------------------------------------
            //
            // Mark the current task as terminated and immediately
            // transfer execution to another runnable task.
            //
            // Resource cleanup is deferred until the scheduler's
            // normal cleanup pass during a later timer interrupt.
            //
            0 => {
                if (manager.tasks[manager.current_task_idx]) |*t| {
                    t.state = .Dead;
                }

                const next_idx = manager.pickNextTask();

                manager.current_task_idx = next_idx;
                manager.tasks[next_idx].?.state = .Running;

                return manager.tasks[next_idx].?.stack_ptr;
            },

            // -----------------------------------------------------------------
            //  SYSCALL 1 - PRINT_STRING
            // -----------------------------------------------------------------
            //
            // Parameters:
            //   rdi = buffer address
            //   rsi = buffer length
            //   rdx = VGA colour attribute
            //
            // Outputs a string to the kernel display subsystem.
            //
            1 => {
                const phys_ptr = blk: {
                    if (manager.tasks[manager.current_task_idx]) |t| {

                        // If the pointer already references the task's
                        // loaded code region, use it directly.
                        if (t.code_phys != 0) {
                            const code_end =
                            t.code_phys + (2 * bm.PAGE_SIZE);

                            if (ctx.rdi >= t.code_phys and
                                ctx.rdi < code_end)
                            {
                                break :blk ctx.rdi;
                            }
                        }

                        // Validate pointers that reference task-stack
                        // memory through the higher-half mapping.
                        if (t.stack_mem) |stack_slice| {
                            const kernel_offset: u64 =
                            0xFFFFFF8000000000;

                            if (ctx.rdi >= kernel_offset) {
                                const stack_phys =
                                memory.virtToPhys(
                                    @intFromPtr(stack_slice.ptr)
                                );

                                const stack_end =
                                stack_phys + stack_slice.len;

                                const rdi_phys =
                                memory.virtToPhys(ctx.rdi);

                                if (rdi_phys >= stack_phys and
                                    rdi_phys < stack_end)
                                {
                                    break :blk rdi_phys;
                                }
                            }
                        }

                        // Fallback interpretation:
                        // treat the caller value as an offset into the
                        // loaded code image.
                        if (t.code_phys != 0) {
                            break :blk t.code_phys + ctx.rdi;
                        }
                    }

                    break :blk ctx.rdi;
                };

                const virt_ptr = memory.physToVirt(phys_ptr);
                const ptr: [*]const u8 = @ptrFromInt(virt_ptr);

                const len: usize = ctx.rsi;

                const colour: u8 =
                if (ctx.rdx == 0)
                    0x0F
                    else
                        @truncate(ctx.rdx);

                const fg: u8 = colour & 0x0F;
                const bg: u8 = (colour >> 4) & 0x0F;

                vga.writeString(ptr[0..len], fg, bg);

                return stack_ptr;
            },

            // -----------------------------------------------------------------
            //  SYSCALL 2 - GET_SCRATCH_BYTE
            // -----------------------------------------------------------------
            //
            // Parameters:
            //   rdi = scratch-page offset
            //
            // Returns:
            //   rax = byte value
            //
            2 => {
                const offset = ctx.rdi;

                if (offset < 4096) {
                    const scratch_virt =
                    memory.physToVirt(SCRATCH_PAGE_PHYS + offset);

                    const val =
                    @as(*volatile u8, @ptrFromInt(scratch_virt)).*;

                    ctx.rax = val;
                }

                return stack_ptr;
            },

            // -----------------------------------------------------------------
            //  SYSCALL 3 - SET_SCRATCH_BYTE
            // -----------------------------------------------------------------
            //
            // Parameters:
            //   rdi = scratch-page offset
            //   rsi = value
            //
            3 => {
                const offset = ctx.rdi;
                const value: u8 = @truncate(ctx.rsi);

                if (offset < 4096) {
                    const scratch_virt =
                    memory.physToVirt(SCRATCH_PAGE_PHYS + offset);

                    @as(
                        *volatile u8,
                        @ptrFromInt(scratch_virt),
                    ).* = value;
                }

                return stack_ptr;
            },

            // -----------------------------------------------------------------
            //  SYSCALL 4 - PRINT_CHAR
            // -----------------------------------------------------------------
            //
            // Parameters:
            //   rdi = character
            //   rsi = colour
            //
            // Outputs a character followed by a newline.
            //
            4 => {
                const char: u8 = @truncate(ctx.rdi);

                const colour: u8 =
                if (ctx.rsi == 0)
                    0x0F
                    else
                        @truncate(ctx.rsi);

                const fg: u8 = colour & 0x0F;
                const bg: u8 = (colour >> 4) & 0x0F;

                const buf = [1]u8{char};
                vga.writeString(&buf, fg, bg);

                const newline = [1]u8{'\n'};
                vga.writeString(&newline, fg, bg);

                return stack_ptr;
            },

            // -----------------------------------------------------------------
            //  SYSCALL 5 - INCREMENT_SCRATCH_BYTE
            // -----------------------------------------------------------------
            //
            // Parameters:
            //   rdi = scratch-page offset
            //   rsi = increment amount
            //
            // Returns:
            //   rax = updated value
            //
            5 => {
                const offset = ctx.rdi;

                if (offset < 4096) {
                    const scratch_virt =
                    memory.physToVirt(SCRATCH_PAGE_PHYS + offset);

                    const ptr =
                    @as(*volatile u8, @ptrFromInt(scratch_virt));

                    const new_val =
                    ptr.* +% @as(u8, @truncate(ctx.rsi));

                    ptr.* = new_val;
                    ctx.rax = new_val;
                }

                return stack_ptr;
            },

            // Unknown syscall.
            //
            // Ignored safely to preserve system stability.
            else => {
                return stack_ptr;
            },
        }
    }

};

// -----------------------------------------------------------------------------
//  GLOBAL SCHEDULER INSTANCE
// -----------------------------------------------------------------------------

/// Singleton scheduler manager used by the kernel.
///
/// Initialised during boot and referenced by interrupt handlers,
/// task-management code, and system-call dispatch.
pub var manager: Scheduler = undefined;


