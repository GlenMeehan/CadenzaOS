; src/kernel/interrupts/irq_stubs.asm
;
; IRQ and exception stubs for x86_64 long mode.
; Provides:
;   • irq0_stub, irq1_stub, irq12_stub
;   • exception0_asm ... exception14_asm
;   • exception_common (calls Zig wrapper)
;
; NOTE:
;   load_idt is NOT defined here — it lives in arch_util.s.
extern load_idt

[BITS 64]

; ---------------------------------------------------------------------------
;  EXTERNAL SYMBOLS
; ---------------------------------------------------------------------------




extern exceptionHandlerWrapper

extern irq0_handler
extern irq1_handler
extern irq12_handler
extern preempt_handler
extern task_exit_handler

global irq0_stub
global irq1_stub
global irq12_stub
global isr80_stub

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

; ---------------------------------------------------------------------------
;  REGISTER SAVE/RESTORE MACROS
; ---------------------------------------------------------------------------

%macro PUSH_REGS 0
    push r15
    push r14
    push r13
    push r12
    push r11
    push r10
    push r9
    push r8
    push rdi
    push rsi
    push rbx
    push rdx
    push rcx
    push rax
    push rbp
%endmacro

%macro POP_REGS 0
    pop rbp
    pop rax
    pop rcx
    pop rdx
    pop rbx
    pop rsi
    pop rdi
    pop r8
    pop r9
    pop r10
    pop r11
    pop r12
    pop r13
    pop r14
    pop r15
%endmacro

; ---------------------------------------------------------------------------
;  IRQ STUBS
; ---------------------------------------------------------------------------

irq0_stub:
    ; 1. Push registers in the exact order Zig's TaskContext expects
    push r15
    push r14
    push r13
    push r12
    push r11
    push r10
    push r9
    push r8
    push rbp
    push rdi
    push rsi
    push rdx
    push rcx
    push rbx
    push rax

    ; 2. Call your passive clock increment and uptime display function
    call irq0_handler

    ; 3. Pass the current stack pointer to the preemption engine
    mov rdi, rsp
    call preempt_handler

    ; 4. Switch stacks to the chosen task's stack pointer
    mov rsp, rax

    ; 5. Pop all 15 registers off the target stack
    pop rax
    pop rbx
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rbp
    pop r8
    pop r9
    pop r10
    pop r11
    pop r12
    pop r13
    pop r14
    pop r15

    ; 6. True hardware interrupt return
    iretq

isr80_stub:
    push r15
    push r14
    push r13
    push r12
    push r11
    push r10
    push r9
    push r8
    push rbp
    push rdi
    push rsi
    push rdx
    push rcx
    push rbx
    push rax

    mov rdi, rsp
    call task_exit_handler

    mov rsp, rax

    pop rax
    pop rbx
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rbp
    pop r8
    pop r9
    pop r10
    pop r11
    pop r12
    pop r13
    pop r14
    pop r15

    iretq

irq1_stub:
    PUSH_REGS
    call irq1_handler
    POP_REGS
    iretq

irq12_stub:
    PUSH_REGS
    call irq12_handler
    POP_REGS
    iretq

; ---------------------------------------------------------------------------
;  EXCEPTION STUBS
; ---------------------------------------------------------------------------
; For exceptions WITHOUT CPU-pushed error code:
;     push 0          ; dummy error code
;     push <num>      ; exception number
;
; For exceptions WITH CPU-pushed error code (8, 13, 14):
;     CPU pushes error code
;     we push only the exception number

exception0_asm:
    push qword 0
    push qword 0
    jmp exception_common

exception1_asm:
    push qword 0
    push qword 1
    jmp exception_common

exception2_asm:
    push qword 0
    push qword 2
    jmp exception_common

exception3_asm:
    push qword 0
    push qword 3
    jmp exception_common

exception4_asm:
    push qword 0
    push qword 4
    jmp exception_common

exception5_asm:
    push qword 0
    push qword 5
    jmp exception_common

exception6_asm:
    push qword 0
    push qword 6
    jmp exception_common

exception7_asm:
    push qword 0
    push qword 7
    jmp exception_common

exception8_asm:
    ; CPU already pushed error code
    push qword 8
    jmp exception_common

exception13_asm:
    ; CPU already pushed error code
    push qword 13
    jmp exception_common

exception14_asm:
    ; CPU already pushed error code
    push qword 14
    jmp exception_common

; ---------------------------------------------------------------------------
;  UNIFIED EXCEPTION HANDLER
; ---------------------------------------------------------------------------

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

    ; --- ALIGNMENT FIX ---
    mov rbp, rsp
    sub rsp, 8          ; ensure 16-byte alignment

    mov rdi, rsp
    add rdi, 8          ; point to (num, error_code)

    call exceptionHandlerWrapper

    add rsp, 8          ; remove alignment padding
    ; --- END ALIGNMENT FIX ---

    ; Restore registers
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax

    add rsp, 16         ; pop (error_code, num)
    iretq
