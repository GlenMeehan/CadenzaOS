# src/kernel/arch_util.s
#
# Architecture‑specific utilities for x86_64.
# Currently provides:
#   • load_idt — load an IDTR pointer using the lidt instruction
#
# Called from Zig as:
#     extern fn load_idt(ptr: *const IDTR) void

    .section .text
    .global load_idt

# rdi contains pointer to IDTR struct
load_idt:
    lidt (%rdi)
    ret

.global switch_tasks

# void switch_tasks(u64* old_rsp, u64 new_rsp)
switch_tasks:
    # 1. Save current registers
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

    # 2. Swap stacks
    movq %rsp, (%rdi)    # Save current RSP
    movq %rsi, %rsp      # Load new RSP

    # 3. Restore registers
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

    # 4. THE CHANGE: Use ret instead of iretq
    ret
