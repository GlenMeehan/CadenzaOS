; src/kernel/interrupts/irq_stubs.asm
;
; IRQ and exception stubs for x86_64 long mode.
;
; Responsibilities:
;   • Entry points for hardware IRQ handlers
;   • Entry points for CPU exception handlers
;   • Common register save/restore logic
;   • Transfer of control from assembly to Zig handlers
;
; Provides:
;   • irq0_stub, irq1_stub, irq12_stub
;   • exception0_asm ... exception14_asm
;   • exception_common (calls Zig wrapper)
;
; NOTE:
;   load_idt is not defined here. It is implemented separately in
;   arch_util.s because it is used outside the interrupt stub layer.

extern load_idt

[BITS 64]

; ---------------------------------------------------------------------------
;  EXTERNAL SYMBOLS
; ---------------------------------------------------------------------------
;
; Implemented in Zig and called once processor state has been saved.

extern exceptionHandlerWrapper

extern irq0_handler
extern irq1_handler
extern irq12_handler
extern preempt_handler
extern syscall_handler

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
;
; These macros preserve the general-purpose register state before
; control is transferred to higher-level Zig handlers.
;
; Register order must remain symmetrical between PUSH_REGS and POP_REGS.
; Any change to one macro must be mirrored in the other.

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
    ; 1. Save the current task context.
    ;
    ; Register order must exactly match the layout expected by the
    ; Zig TaskContext structure and the scheduler restore path.
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

    ; 2. Run the timer IRQ handler.
    ;    This typically updates kernel timekeeping and other
    ;    tick-driven services.
    call irq0_handler

    ; 3. Pass the saved context pointer to the scheduler.
    ;    rdi = pointer to current TaskContext on the stack.
    mov rdi, rsp
    call preempt_handler

    ; 4. Switch to the stack belonging to the selected task.
    ;    The scheduler returns the next task's saved stack pointer in rax.
    mov rsp, rax

    ; 5. Restore the selected task's register state.
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

    ; 6. Return from the hardware interrupt.
    ;    Execution resumes in the selected task.
    iretq

isr80_stub:
    ; Save caller context before entering the syscall handler.
    ; Uses the same layout as TaskContext for consistency.
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

    ; Pass a pointer to the saved register frame.
    mov rdi, rsp
    call syscall_handler

    ; Switch to the context returned by the syscall layer.
    mov rsp, rax

    ; Restore the selected context.
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
    ; Keyboard IRQ.
    PUSH_REGS
    call irq1_handler
    POP_REGS
    iretq

irq12_stub:
    ; PS/2 mouse IRQ.
    PUSH_REGS
    call irq12_handler
    POP_REGS
    iretq

; ---------------------------------------------------------------------------
;  EXCEPTION STUBS
; ---------------------------------------------------------------------------
;
; The common exception handler expects the stack layout:
;
;     exception_number
;     error_code
;
; Exceptions without a CPU-supplied error code push a dummy zero.
;
; Exceptions with a CPU-supplied error code:
;     8   = Double Fault
;     13  = General Protection Fault
;     14  = Page Fault
;
; already have an error code on the stack, so only the exception
; number is added before entering exception_common.

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
    ; CPU already pushed an error code.
    push qword 8
    jmp exception_common

exception13_asm:
    ; CPU already pushed an error code.
    push qword 13
    jmp exception_common

exception14_asm:
    ; CPU already pushed an error code.
    push qword 14
    jmp exception_common

; ---------------------------------------------------------------------------
;  UNIFIED EXCEPTION HANDLER
; ---------------------------------------------------------------------------

exception_common:

    ; Save caller-saved registers that may be modified by Zig code.
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11

    ; Ensure the stack is 16-byte aligned before making a call
    ; into Zig code, as required by the SysV x86_64 ABI.
    mov rbp, rsp
    sub rsp, 8

    ; Pass a pointer to the exception frame:
    ;
    ;     exception_number
    ;     error_code
    ;
    ; plus any CPU-supplied interrupt frame beneath it.
    mov rdi, rsp
    add rdi, 8

    call exceptionHandlerWrapper

    ; Remove temporary alignment padding.
    add rsp, 8

    ; Restore preserved registers.
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax

    ; Discard:
    ;     exception_number
    ;     error_code
    ;
    ; leaving the original CPU interrupt frame for iretq.
    add rsp, 16

    iretq
