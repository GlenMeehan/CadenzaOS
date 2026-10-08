# src/kernel/arch_util.s
#
# Architecture-specific utilities for x86_64.
#
# Currently provides:
#   • load_idt     — load an IDT descriptor using the lidt instruction
#   • switch_tasks — low-level cooperative task context switch
#
# Called from Zig as:
#     extern fn load_idt(ptr: *const IDTR) void

    .section .text
    .global load_idt

# rdi contains a pointer to an IDTR structure.
#
# The IDTR format must match the layout expected by the x86_64
# lidt instruction.
load_idt:
    lidt (%rdi)
    ret

.global switch_tasks

# void switch_tasks(u64* old_rsp, u64 new_rsp)
#
# Parameters (SysV ABI):
#     rdi = pointer to storage for current task's RSP
#     rsi = saved RSP of the task being resumed
#
# The stack referenced by new_rsp is expected to contain a complete
# saved register frame laid out in the same order used below.
switch_tasks:

    # 1. Save the current task's CPU context.
    #
    # Register order must exactly match the restore path and the
    # stack layout expected by the scheduler.
    push %rax
    push %rbx
    push %rcx
    push %rdx
    push %rsi
    push %rdi
    push %rbp
    push %r8
    push %r9
    push %r10
    push %r11
    push %r12
    push %r13
    push %r14
    push %r15

    # 2. Save the current stack pointer and load the target task's
    #    previously saved stack pointer.
    movq %rsp, (%rdi)
    movq %rsi, %rsp

    # 3. Restore the target task's CPU context.
    #
    # The new stack must contain registers in the reverse order of
    # the save sequence above.
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %r11
    pop %r10
    pop %r9
    pop %r8
    pop %rbp
    pop %rdi
    pop %rsi
    pop %rdx
    pop %rcx
    pop %rbx
    pop %rax

    # 4. Resume execution on the restored task.
    #
    # This routine performs a normal task-to-task switch rather than
    # returning from an interrupt, so a standard RET is used instead
    # of IRETQ.
    ret
