;src/kernel/arch_util.s

.section .text
.global load_idt

# rdi will contain the pointer to the IDTR struct
load_idt:
    lidt (%rdi)
    ret
