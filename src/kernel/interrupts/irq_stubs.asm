; src/kernel/interrupts/irq_stubs.asm

global irq0_stub
extern irq0_handler
global irq1_stub
extern irq1_handler
global irq12_stub
extern irq12_handler

[BITS 64]

irq0_stub:
    push rbp
    mov rbp, rsp

    push rax
    push rcx
    push rdx
    push rbx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11

    call irq0_handler

    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbx
    pop rdx
    pop rcx
    pop rax
    pop rbp
    iretq

irq1_stub:
    push rbp
    mov rbp, rsp

    push rax
    push rcx
    push rdx
    push rbx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11

    call irq1_handler

    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbx
    pop rdx
    pop rcx
    pop rax
    pop rbp
    iretq

irq12_stub:
    push rbp
    mov rbp, rsp

    push rax
    push rcx
    push rdx
    push rbx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11

    call irq12_handler

    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbx
    pop rdx
    pop rcx
    pop rax
    pop rbp
    iretq
