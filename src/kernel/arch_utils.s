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
