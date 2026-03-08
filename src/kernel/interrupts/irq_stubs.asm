; src/kernel/interrupts/irq_stubs.asm

global exception0_asm
global exception1_asm
global exception2_asm
global exception3_asm
global exception4_asm
global exception5_asm
global exception6_asm
global exception7_asm
global exception8_asm
global exception13_asm
global exception14_asm

extern exceptionHandlerWrapper

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

    global load_idt

    ; Add this implementation to the bottom
    load_idt:
        lidt [rdi]    ; In x86_64 SysV, the first argument is in RDI
        ret

exception0_asm:
    push qword 0      ; Dummy error code
    push qword 0      ; Exception number 0
    jmp exception_common

exception1_asm:
    push qword 0      ; Dummy error code
    push qword 1      ; Exception number 1
    jmp exception_common

exception2_asm:
    push qword 0      ; Dummy error code
    push qword 2      ; Exception number 1
    jmp exception_common

exception3_asm:
    push qword 0      ; Dummy error code
    push qword 3      ; Exception number 1
    jmp exception_common

exception4_asm:
    push qword 4      ; Dummy error code
    push qword 1      ; Exception number 1
    jmp exception_common

exception5_asm:
    push qword 0      ; Dummy error code
    push qword 5      ; Exception number 1
    jmp exception_common

exception6_asm:
    push qword 0      ; Dummy error code
    push qword 6      ; Exception number 1
    jmp exception_common

exception7_asm:
    push qword 0      ; Dummy error code
    push qword 7      ; Exception number 1
    jmp exception_common

exception8_asm:
    push qword 0      ; Dummy error code
    push qword 8      ; Exception number 1
    jmp exception_common


; ... Exceptions 2-7 follow the same pattern ...

exception13_asm:
    ; CPU ALREADY PUSHED error code here
    push qword 13     ; Exception number 13
    jmp exception_common

exception14_asm:
    ; CPU ALREADY PUSHED error code here
    push qword 14     ; Exception number 13
    jmp exception_common


; --- The Unified Handler ---

exception_common:
    ; Save registers
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11

    ; --- ALIGNMENT FIX START ---
    mov rbp, rsp           ; Save current stack in RBP (need to mark RBP as used)
    sub rsp, 8             ; Push 8 bytes to ensure 16-byte alignment
                           ; (We pushed 9 regs + 2 error/num = 11.
                           ; 11 * 8 = 88. 88 + 8 = 96. 96 is div by 16!)

    mov rdi, rsp           ; Pass aligned stack pointer to Zig
    add rdi, 8             ; Point RDI to the ACTUAL start of our data

    call exceptionHandlerWrapper

    add rsp, 8             ; Clean up the alignment padding
    ; --- ALIGNMENT FIX END ---

    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    add rsp, 16            ; Clean up error code and num
    iretq
