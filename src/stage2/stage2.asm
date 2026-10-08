; ==============================================================================
; File: src/stage2/stage2.asm
; Description: Stage 2 Bootloader — Real Mode → Unreal Mode → Protected Mode → Long Mode
;
; Memory Layout & Base Setup:
;   0x7E00 - 0xA5FF  : Stage 2 Code & Local Structures
;   0x1000 - 0x5FFF  : Early Page Tables (PML4, PDPTs, PD, PT)
;   0x7000 - 0x709F  : Boot Info Structure (Passed to kernel in RDI)
;   0x9000 - 0x92FF  : E820 Memory Map Buffer
;   0x10000          : Disk Read Bounce Buffer (64 KiB space)
;   0x20000          : Task State Segment (TSS)
;   0x70000          : Early 32-bit Stack Top
;   0x100000 (1 MiB) : Kernel Physical Load Base Target
; ==============================================================================

[org 0x7E00]
[bits 16]

start:
    ; Bypass entry header padding directly to main setup
    jmp start2

; ==============================================================================
; GLOBAL CONSTANTS & MEMORY MAP CONFIGURATION
; ==============================================================================
E820_BUF          equ 0x9000          ; Buffer storing raw E820 entries
MMAP_COUNT        equ 0x8FF8          ; Storage location for total E820 entry count

KERNEL_OFFSET     equ 0xFFFFFF8000000000 ; High-half virtual address offset
KERNEL_LOAD_PHYS  equ 0x00100000      ; Physical load address: 1 MiB boundary
%include "build/kernel_info.inc"      ; Imports KERNEL_SECTORS and KERNEL_ENTRY

EARLY_STACK_TOP   equ 0x70000         ; Temporary stack top before entering long mode
KERNEL_STACK_TOP  equ 0xC0000         ; Dedicated Kernel stack physical boundary
KERNEL_PHYS_ENTRY equ KERNEL_LOAD_PHYS + (KERNEL_ENTRY - KERNEL_OFFSET)

; Page Table Locations (4 KiB aligned per table)
PML4_ADDR         equ 0x1000          ; Page Map Level 4 Table Base
PDPT_ADDR         equ 0x2000          ; Page Directory Pointer Table Base (Identity)
PD_ADDR           equ 0x3000          ; Page Directory Table Base (2 MiB Huge Pages)
PDPT_KERNEL_ADDR  equ 0x4000          ; Page Directory Pointer Table Base (Kernel High-Half)
PT_KERNEL_ADDR    equ 0x5000          ; Page Table Base (Kernel Fine-grained 4 KiB)

TSS_PHYS_ADDR     equ 0x20000         ; Task State Segment Base (104 bytes)
IST1_STACK_TOP    equ 0x25000         ; Interrupt Stack Table 1 top (16 KiB size)

VBE_MODE_INFO     equ 0xA000          ; Buffer to hold temporary VBE mode structure

; Graphics Mode Configuration: 0 = Legacy VGA Text (80x25), 1 = VESA VBE (1024x768x32)
GRAPHICS_MODE_SEL equ 1

BOOT_INFO_ADDR    equ 0x7000          ; Shared Boot Info Structure Base Location

; ==============================================================================
; DATA SECTION & STRUCTURE DEFINITIONS (Real Mode Accessible)
; ==============================================================================
ata_drive_sel:    db 0xE0             ; Primary Master ATA Drive Select Byte

align 4
; Disk Address Packet (DAP) structure for BIOS INT 13h AH=42h
kernel_dap:
    db 0x10                           ; DAP size (16 bytes)
    db 0x00                           ; Reserved (must be 0)
dap_sector_count:
    dw 32                             ; Sectors per read chunk (32 sectors = 16 KiB)
dap_buffer_off:
    dw 0x0000                         ; Destination segment offset
dap_buffer_seg:
    dw 0x1000                         ; Destination segment base (0x1000 * 16 = 0x10000 physical)
dap_lba_low:
    dd 16                             ; Start LBA (LBA 16 = Kernel start position)
dap_lba_high:
    dd 0                              ; Upper 32 bits of LBA

boot_drive:        db 0x80            ; Saved drive ID passed from Stage 1
sectors_remaining: dw KERNEL_SECTORS  ; Track count of unread kernel sectors

; ------------------------------------------------------------------------------
; 16-bit Serial Routines (COM1 - 0x3F8)
; ------------------------------------------------------------------------------
serial_init16:
    push ax
    push dx
    mov dx, 0x3F9
    xor al, al
    out dx, al                        ; Disable interrupts on COM1
    mov dx, 0x3FB
    mov al, 0x80
    out dx, al                        ; Enable DLAB (set baud rate divisor)
    mov dx, 0x3F8
    mov al, 0x03
    out dx, al                        ; Set divisor to 3 (38400 baud)
    mov dx, 0x3F9
    xor al, al
    out dx, al                        ; High byte of divisor
    mov dx, 0x3FB
    mov al, 0x03
    out dx, al                        ; 8 bits, no parity, one stop bit
    mov dx, 0x3FC
    mov al, 0x03
    out dx, al                        ; Enable RTS/DTR
    pop dx
    pop ax
    ret

serial_putchar16:
    push ax
    push dx
.wait_thre16:
    mov dx, 0x3FD
    in al, dx
    test al, 0x20                     ; Check Transmitter Holding Register Empty (THRE)
    jz .wait_thre16
    pop dx
    pop ax
    push dx
    mov dx, 0x3F8
    out dx, al                        ; Transmit character
    pop dx
    ret

; ==============================================================================
; REAL MODE ENTRY POINT
; ==============================================================================
start2:
    call serial_init16
    mov al, 'S'
    call serial_putchar16             ; Debug: Output Stage 2 Start

    mov ah, 0x0E
    mov al, 'A'
    int 0x10                          ; VGA Video Output
    mov al, 'A'
    call serial_putchar16

    ; Save drive ID provided by Stage 1/BIOS
    mov [boot_drive], dl

    ; Setup basic Real Mode segments and stack
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x5000

    mov ah, 0x0E
    mov al, 'A'
    int 0x10

; ------------------------------------------------------------------------------
; Transition to Unreal Mode (Unlocks >1MB Addressing in 16-bit Mode)
; ------------------------------------------------------------------------------
    mov eax, gdt_start
    mov [gdt_descriptor + 2], eax
    lgdt [gdt_descriptor]

    cli                               ; Disable interrupts during mode switch

    mov eax, cr0
    or al, 0x01                       ; Enable Protected Mode temporarily (PE=1)
    mov cr0, eax

    jmp $+2                           ; Flush instruction pipeline

    mov bx, 0x10                      ; Selector 0x10 (32-bit Flat Data Descriptor)
    mov ds, bx                        ; Load 4 GiB descriptor limits into segment caches
    mov es, bx
    mov fs, bx
    mov gs, bx

    and al, 0xFE                      ; Disable Protected Mode (PE=0)
    mov cr0, eax

    jmp $+2                           ; Flush pipeline back to 16-bit real mode

    ; Restore 16-bit segment selectors while retaining the expanded 4 GiB limits
    xor ax, ax
    mov ds, ax
    mov es, ax

    sti                               ; Re-enable interrupts

; ------------------------------------------------------------------------------
; Load Kernel to High Memory (1 MiB+) using Unreal Mode & Bounce Buffer
; ------------------------------------------------------------------------------
    mov edi, KERNEL_LOAD_PHYS         ; Target destination pointer (0x00100000 = 1 MiB)

.read_kernel_loop:
    cmp word [sectors_remaining], 0
    je .disk_read_ok

    ; Determine current chunk size (Max 32 sectors per call)
    mov ax, [sectors_remaining]
    cmp ax, 32
    jbe .set_chunk_size
    mov ax, 32

.set_chunk_size:
    mov [dap_sector_count], ax

    ; Keep bounce buffer constant at 0x10000 (0x1000:0x0000)
    mov word [dap_buffer_seg], 0x1000
    mov word [dap_buffer_off], 0x0000

    ; Extended Read via BIOS (INT 13h, AH=42h)
    lea si, [kernel_dap]
    mov dl, [boot_drive]
    mov ah, 0x42
    int 0x13
    jc .disk_read_failed

    ; Copy chunk from low bounce buffer (0x10000) to High RAM via FS override
    movzx ecx, word [dap_sector_count]
    shl ecx, 7                        ; Convert sectors to DWORD count (sectors * 128)

    mov esi, 0x00010000               ; Source address in bounce buffer

    push ds
    xor ax, ax
    mov ds, ax                        ; Ensure base DS = 0

.copy_chunk:
    a32 mov eax, [esi]                ; Fetch 32-bit DWORD from low memory
    a32 mov [fs:edi], eax             ; Write 32-bit DWORD into high memory (>1 MiB)
    add esi, 4
    add edi, 4
    loop .copy_chunk

    pop ds                            ; Restore DS

    ; Update tracking metrics for next chunk iteration
    movzx eax, word [dap_sector_count]
    sub [sectors_remaining], ax
    add dword [dap_lba_low], eax

    jmp .read_kernel_loop

.disk_read_failed:
    mov ah, 0x0E
    mov al, 'E'
    int 0x10
    cli
.error_loop:
    hlt
    jmp .error_loop

.disk_read_ok:
    mov ah, 0x0E
    mov al, 'R'                       ; Read OK status
    int 0x10

    ; Zero out Kernel BSS Region
    mov edi, BSS_PHYS
    mov ecx, BSS_SIZE_DWORDS
    xor eax, eax

.zero_bss_loop:
    a32 mov [fs:edi], eax
    add edi, 4
    loop .zero_bss_loop

    mov ah, 0x0E
    mov al, 'B'                       ; BSS zeroed status
    int 0x10

; ==============================================================================
; E820 MEMORY MAP DETECTION
; ==============================================================================
    mov di, E820_BUF
    xor ebx, ebx
    xor bp, bp                        ; BP = Entry counter

.e820_loop:
    mov edx, 0x534D4150               ; 'SMAP' magic constant
    mov eax, 0xE820
    mov ecx, 24                       ; Request 24 bytes per entry
    int 0x15
    jc  .e820_done                    ; Carry set = read complete or error
    cmp eax, 0x534D4150               ; Verify signature match
    jne .e820_done

    add di, 24
    inc bp

    cmp bp, 32                        ; Cap entry collection at 32 entries
    jge .e820_done

    test ebx, ebx                     ; EBX = 0 signals last entry
    jnz .e820_loop

.e820_done:
    movzx eax, bp
    mov [MMAP_COUNT], eax             ; Save collected E820 count

    mov ah, 0x0E
    mov al, 'M'                       ; Memory Map success status
    int 0x10

; ==============================================================================
; GRAPHICS INITIALIZATION (VESA VBE OR VGA TEXT)
; ==============================================================================
%if GRAPHICS_MODE_SEL == 1
    ; Query VBE Controller Info (0x4F00)
    xor ax, ax
    mov es, ax
    mov di, VBE_MODE_INFO

    mov cx, 128
    xor eax, eax
    rep stosd                         ; Clear 512 bytes buffer

    mov di, VBE_MODE_INFO
    mov dword [es:di], 'VBE2'          ; Request VBE 2.0+ specifications

    mov ax, 0x4F00
    int 0x10
    cmp ax, 0x004F
    jne .vesa_fail

    ; Clear buffer prior to querying Mode Information
    mov di, VBE_MODE_INFO
    mov cx, 64
    xor eax, eax
    rep stosd

    ; Query Selected Mode Properties (0x4F01 - Mode 0x0115: 1024x768x32)
    mov ax, 0x4F01
    mov cx, 0x0115
    mov di, VBE_MODE_INFO
    int 0x10
    cmp ax, 0x004F
    jne .vesa_fail

    ; Activate Graphics Mode with Linear Framebuffer (0x4F02 - Mode 0x4115)
    mov ax, 0x4F02
    mov bx, 0x4115
    int 0x10
    cmp ax, 0x004F
    jne .vesa_fail

    mov al, '1'
    call serial_putchar16
    jmp .graphics_done

.vesa_fail:
    mov al, 'F'
    call serial_putchar16
    mov al, '2'
    call serial_putchar16
    jmp $                             ; Hang execution on graphics setup failure
%else
    ; Fallback to standard VGA 80x25 Text Mode
    mov ax, 0x03
    int 0x10
%endif

.graphics_done:
    mov ah, 0x0E
%if GRAPHICS_MODE_SEL == 1
    mov al, 'V'                       ; VESA Selected
    mov al, '3'
    call serial_putchar16
%else
    mov al, 'G'                       ; VGA Selected
%endif
    int 0x10

; ==============================================================================
; PRE-PROTECTED MODE SETUP (A20 LINE & GDT INSTALL)
; ==============================================================================
    xor ax, ax
    mov ds, ax
    mov es, ax

    ; Enable A20 Address Line via Fast A20 Gate (System Control Port A)
    in  al, 0x92
    or  al, 2
    out 0x92, al

    ; Copy GDT to fixed target location (0x0500)
    mov si, gdt_start
    mov di, gdt_base
    mov cx, gdt_end - gdt_start
    rep movsb

    ; Build GDTR frame directly on current stack frame
    push dword 0x0500                 ; GDT Base Pointer Address
    push word (gdt_end - gdt_start - 1) ; GDT Limit

    mov bx, sp
    lgdt [bx]                         ; Load Global Descriptor Table Register
    add sp, 6                         ; Restore stack balance

    cli                               ; Ensure interrupts masked prior to PM transition

; ==============================================================================
; ENTER PROTECTED MODE (32-BIT)
; ==============================================================================
    mov eax, cr0
    or  eax, 1                        ; Set CR0.PE (Bit 0)
    mov cr0, eax

    ; Far jump flushes instruction pipeline and selects 32-bit Code Segment
    jmp 0x08:pm_entry

; ==============================================================================
; GLOBAL DESCRIPTOR TABLE DEFINITIONS
; ==============================================================================
gdt_base equ 0x500

align 8
gdt_start:
    dq 0x0000000000000000             ; Null Descriptor               (Selector 0x00)
    dq 0x00CF9A000000FFFF             ; 32-bit Code Segment (DPL 0)   (Selector 0x08)
    dq 0x00CF92000000FFFF             ; 32-bit Data Segment (DPL 0)   (Selector 0x10)
    dq 0x00209A0000000000             ; 64-bit Code Segment (DPL 0)   (Selector 0x18)
    dq 0x0000920000000000             ; 64-bit Data Segment (DPL 0)   (Selector 0x20)

    ; 64-bit TSS Descriptor (16 Bytes Total) — Selector 0x28
    db 0x67, 0x00                     ; Limit [15:0] = 103 (sizeof(TSS)-1)
    db 0x00, 0x00                     ; Base [15:0]  = 0x0000
    db 0x02                           ; Base [23:16] = 0x02 (Base = 0x00020000)
    db 0x89                           ; Access: Present, DPL 0, Executable, 64-bit TSS
    db 0x00                           ; Granularity & Limit [19:16]
    db 0x00                           ; Base [31:24]
    dq 0x0000000000000000             ; Base [63:32] + Reserved
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start

message_pm:
    db 'P', 'M', '!'

; ==============================================================================
; PROTECTED MODE (32-bit Execution Frame)
; ==============================================================================
[BITS 32]
pm_entry:
    ; Update Data Segment Selectors to 32-bit Data Descriptor (0x10)
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov esp, EARLY_STACK_TOP

%if GRAPHICS_MODE_SEL == 0
    ; Print 'PM!' directly to Video Memory (0xB8000) in legacy VGA mode
    mov esi, message_pm
    mov edi, 0xB8000
    mov ecx, 3
.print_loop:
    lodsb
    mov ah, 0x0F                      ; White text on black background
    stosw
    loop .print_loop
%endif

; ------------------------------------------------------------------------------
; POPULATE BOOT INFORMATION STRUCTURE (At 0x7000)
; ------------------------------------------------------------------------------
    ; kernel_phys_start (Offset 0x00)
    mov dword [BOOT_INFO_ADDR + 0x00], KERNEL_LOAD_PHYS
    mov dword [BOOT_INFO_ADDR + 0x04], 0x00000000

    ; Calculate kernel byte size (Sectors * 512)
    mov eax, KERNEL_SECTORS
    imul eax, 512

    ; kernel_phys_end (Offset 0x08)
    mov edx, eax
    add edx, KERNEL_LOAD_PHYS
    mov dword [BOOT_INFO_ADDR + 0x08], edx
    mov dword [BOOT_INFO_ADDR + 0x0C], 0x00000000

    ; kernel_size_bytes (Offset 0x10)
    mov dword [BOOT_INFO_ADDR + 0x10], eax
    mov dword [BOOT_INFO_ADDR + 0x14], 0x00000000

    ; kernel_stack_top (Offset 0x18)
    mov dword [BOOT_INFO_ADDR + 0x18], KERNEL_STACK_TOP
    mov dword [BOOT_INFO_ADDR + 0x1C], 0x00000000

    ; e820_entry_count (Offset 0x20)
    mov eax, [MMAP_COUNT]
    mov dword [BOOT_INFO_ADDR + 0x20], eax

    ; graphics_mode (Offset 0x24)
    mov dword [BOOT_INFO_ADDR + 0x24], GRAPHICS_MODE_SEL

    ; e820_buffer_addr (Offset 0x28)
    mov dword [BOOT_INFO_ADDR + 0x28], E820_BUF
    mov dword [BOOT_INFO_ADDR + 0x2C], 0x00000000

    ; pml4_addr (Offset 0x30)
    mov dword [BOOT_INFO_ADDR + 0x30], PML4_ADDR
    mov dword [BOOT_INFO_ADDR + 0x34], 0x00000000

    ; framebuffer_addr (Offset 0x38)
    mov eax, [VBE_MODE_INFO + 40]     ; Linear Framebuffer Base Pointer
    mov dword [BOOT_INFO_ADDR + 0x38], eax
    mov dword [BOOT_INFO_ADDR + 0x3C], 0x00000000

    ; Framebuffer layout details
    movzx eax, word [VBE_MODE_INFO + 0x10] ; Stride (Bytes Per Scanline)
    mov dword [BOOT_INFO_ADDR + 0x40], eax
    mov dword [BOOT_INFO_ADDR + 0x44], 0

    movzx eax, word [VBE_MODE_INFO + 0x12] ; Horizontal Resolution
    mov dword [BOOT_INFO_ADDR + 0x48], eax
    mov dword [BOOT_INFO_ADDR + 0x4C], 0

    movzx eax, word [VBE_MODE_INFO + 0x14] ; Vertical Resolution
    mov dword [BOOT_INFO_ADDR + 0x50], eax
    mov dword [BOOT_INFO_ADDR + 0x54], 0

    movzx eax, byte [VBE_MODE_INFO + 0x19]  ; Bits Per Pixel
    mov dword [BOOT_INFO_ADDR + 0x58], eax
    mov dword [BOOT_INFO_ADDR + 0x5C], 0

    ; Color bitmask metrics
    movzx eax, byte [VBE_MODE_INFO + 0x1F] ; Red Mask Size
    mov dword [BOOT_INFO_ADDR + 0x60], eax
    mov dword [BOOT_INFO_ADDR + 0x64], 0

    movzx eax, byte [VBE_MODE_INFO + 0x20] ; Red Position
    mov dword [BOOT_INFO_ADDR + 0x68], eax
    mov dword [BOOT_INFO_ADDR + 0x6C], 0

    movzx eax, byte [VBE_MODE_INFO + 0x21] ; Green Mask Size
    mov dword [BOOT_INFO_ADDR + 0x70], eax
    mov dword [BOOT_INFO_ADDR + 0x74], 0

    movzx eax, byte [VBE_MODE_INFO + 0x22] ; Green Position
    mov dword [BOOT_INFO_ADDR + 0x78], eax
    mov dword [BOOT_INFO_ADDR + 0x7C], 0

    movzx eax, byte [VBE_MODE_INFO + 0x23] ; Blue Mask Size
    mov dword [BOOT_INFO_ADDR + 0x80], eax
    mov dword [BOOT_INFO_ADDR + 0x84], 0

    movzx eax, byte [VBE_MODE_INFO + 0x24] ; Blue Position
    mov dword [BOOT_INFO_ADDR + 0x88], eax
    mov dword [BOOT_INFO_ADDR + 0x8C], 0

    movzx eax, byte [VBE_MODE_INFO + 0x25] ; Reserved Mask Size
    mov dword [BOOT_INFO_ADDR + 0x90], eax
    mov dword [BOOT_INFO_ADDR + 0x94], 0

    movzx eax, byte [VBE_MODE_INFO + 0x26] ; Reserved Position
    mov dword [BOOT_INFO_ADDR + 0x98], eax
    mov dword [BOOT_INFO_ADDR + 0x9C], 0

; ==============================================================================
; BUILD PAGE TABLES FOR LONG MODE (4-Level Paging)
; Architecture: PML4 -> PDPT -> PD (2 MiB Huge Pages)
; ==============================================================================

    ; 1. Clear Page Tables memory area (PML4 through PT_KERNEL)
    mov edi, PML4_ADDR
    mov ecx, 4096 / 4 * 4             ; Zero page tables memory
    xor eax, eax
    rep stosd

    ; 2. Link PML4 Entries
    mov edi, PML4_ADDR

    ; Identity Mapping: PML4[0] -> PDPT_ADDR
    mov eax, PDPT_ADDR | 0x03         ; Present + Read/Write
    mov [edi + 0 * 8], eax
    mov dword [edi + 0 * 8 + 4], 0

    ; Kernel High-Half Mapping: PML4[510] -> PDPT_KERNEL_ADDR
    mov eax, PDPT_KERNEL_ADDR | 0x03
    mov [edi + 510 * 8], eax
    mov dword [edi + 510 * 8 + 4], 0

    ; Recursive/Higher Reference Link: PML4[511] -> PDPT_ADDR
    mov eax, PDPT_ADDR | 0x03
    mov [edi + 511 * 8], eax
    mov dword [edi + 511 * 8 + 4], 0

    ; 3. Link Directory Pointer Entries
    mov edi, PDPT_ADDR
    mov eax, PD_ADDR | 0x03
    mov [edi + 0 * 8], eax            ; Identity PDPT[0] -> PD_ADDR
    mov dword [edi + 0 * 8 + 4], 0

    mov edi, PDPT_KERNEL_ADDR
    mov eax, PD_ADDR | 0x03           ; High-Half PDPT[0] -> PD_ADDR
    mov [edi + 0 * 8], eax
    mov dword [edi + 0 * 8 + 4], 0

    ; 4. Populate Identity & High-Half Memory Pages (64 MiB space)
    mov edi, PD_ADDR
    mov eax, 0x00000000               ; Start physical address: 0x0
    mov ebx, 0x04000000               ; Upper boundary limit: 64 MiB
    xor ecx, ecx

map_kernel_pages:
    cmp eax, ebx
    jge .done_mapping_kernel

    mov edx, eax
    or  edx, 0x83                     ; Present + Read/Write + Page Size (2 MiB Huge Page)
    mov [edi + ecx * 8], edx
    mov dword [edi + ecx * 8 + 4], 0

    add eax, 0x200000                 ; Advance physical address by 2 MiB
    inc ecx
    jmp map_kernel_pages

.done_mapping_kernel:

    ; Map Linear Framebuffer Space (Offset 496 in Page Directory)
    mov eax, [VBE_MODE_INFO + 40]
    and eax, 0xFFE00000               ; Align framebuffer address to 2 MiB
    or  eax, 0x83                     ; Present + Read/Write + Huge Page
    mov [edi + 496 * 8], eax
    mov dword [edi + 496 * 8 + 4], 0

    ; Update Framebuffer Base in Boot Info mapping
    mov dword [BOOT_INFO_ADDR + 0x38], 0x3E000000
    mov dword [BOOT_INFO_ADDR + 0x3C], 0x00000000

%if GRAPHICS_MODE_SEL == 0
    mov word [0xB8006], 0x0F54        ; Signal 'T'
%endif

; ==============================================================================
; LONG MODE INITIALIZATION CONTROL STEPS
; ==============================================================================
    ; Set Page Directory Base Register (CR3) to PML4 Root
    mov eax, PML4_ADDR
    mov cr3, eax

    ; Enable Physical Address Extension (PAE - CR4.PAE Bit 5)
    mov eax, cr4
    or  eax, 1 << 5
    mov cr4, eax

%if GRAPHICS_MODE_SEL == 0
    mov word [0xB8008], 0x0F50        ; Signal 'P'
%endif

    ; Enable Long Mode active state in EFER Model Specific Register
    mov ecx, 0xC0000080               ; IA32_EFER MSR ID
    rdmsr
    or  eax, 1 << 8                   ; Assert LME (Long Mode Enable, Bit 8)
    wrmsr

%if GRAPHICS_MODE_SEL == 0
    mov word [0xB800A], 0x0F45        ; Signal 'E'
%endif

; ==============================================================================
; ACTIVATE LONG MODE & PAGING ENGINE
; ==============================================================================
%if GRAPHICS_MODE_SEL == 0
    mov word [0xB800E], 0x0F51        ; Signal 'Q'
%endif

    ; Enable Paging Engine (CR0.PG Bit 31) -> Triggers Long Mode transition
    mov eax, cr0
    or  eax, 0x80000000
    mov cr0, eax

print_far_ptr:
    mov esi, long_mode_ptr            ; Load address of long mode far pointer
    mov edi, 0xb8000
    mov ecx, 10

.print_loop:
    mov al, [esi]
    mov ah, 0x0F
    mov [edi], ax
    inc esi
    add edi, 2
    loop .print_loop

    ; Transition to 64-bit Sub-Mode via Code Segment Far Jump (0x18)
    jmp 0x18:long_mode_entry

    cli
    mov word [0xB8010], 0x0F58
.hang:
    hlt
    jmp .hang

; ==============================================================================
; LONG MODE EXECUTION ENVIRONMENT (64-BIT NATIVE)
; ==============================================================================
VGA_TEXT equ 0xB8000

long_mode_ptr:
    dq long_mode_entry                ; 64-bit Entry Pointer Target
    dw 0x18                           ; 64-bit Code Segment Selector

[BITS 64]
serial_putchar64:
    push rax
    push rdx
.wait_thre64:
    mov dx, 0x3FD
    in al, dx
    test al, 0x20
    jz .wait_thre64
    pop rdx
    pop rax
    push rdx
    mov dx, 0x3F8
    out dx, al                        ; Send output byte to Serial port
    pop rdx
    ret

long_mode_entry:
    mov word [0xB8010], 0x0F2A
    mov word [0xB8020], 0x0F52

    ; Update Segment Selectors to 64-bit Data Segment (0x20)
    mov ax, 0x20
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov fs, ax
    mov gs, ax

    ; Load Task Register (TSS Selector 0x28)
    mov ax, 0x28
    ltr ax
    mov al, 'T'
    call serial_putchar64

    ; Establish System V ABI Aligned Stack Frame (16-byte boundary)
    mov rax, 0xFFFFFF8000080000
    and rax, -16
    mov rsp, rax

    ; Configure Floating Point Unit (FPU) & SSE Support
    mov rax, cr0
    and ax, 0xFFFB                    ; Mask EM (Emulation Bit 2)
    or  ax, 0x0002                    ; Set MP (Monitor Coprocessor Bit 1)
    mov cr0, rax

    ; Set OSFXSR (Bit 9) and OSXMMEXCPT (Bit 10) in CR4 for SIMD Instructions
    mov rax, cr4
    or  ax, 0x0600
    mov cr4, rax

%if GRAPHICS_MODE_SEL == 0
    mov rdi, VGA_TEXT
    mov word [rdi + 0x12], 0x0F36     ; Print '6'
    mov word [rdi + 0x14], 0x0F34     ; Print '4'
%endif

    ; Pass pointer to Boot Info Structure as 1st Argument (RDI) via System V ABI
    mov rdi, BOOT_INFO_ADDR

    mov al, 'K'
    call serial_putchar64

    ; Transfer Execution Control to Kernel Entry Point
    mov rax, KERNEL_ENTRY
    jmp rax
