; src/stage2/stage2.asm
; Stage 2 Bootloader - Transitions to 64-bit Long Mode
; Flow: Real Mode → Protected Mode → Long Mode → Kernel

[org 0x7E00]
[bits 16]

;==================================================================================================
; MEMORY MAP CONSTANTS
;==================================================================================================
E820_BUF         equ 0x9000          ; E820 memory map storage
MMAP_COUNT       equ 0x8FF8          ; E820 entry count (32-bit)

KERNEL_OFFSET    equ 0xFFFFFFFF80000000
KERNEL_LOAD_PHYS equ 0x00100000
%include "build/kernel_info.inc"     ; Defines KERNEL_SECTORS

EARLY_STACK_TOP  equ 0x70000         ; Early stack top (grows down)
KERNEL_STACK_TOP equ 0x80000         ; Kernel stack top

; Page table locations
PML4_ADDR        equ 0x1000          ; Page Map Level 4
PDPT_ADDR        equ 0x2000          ; Page Directory Pointer Table
PD_ADDR          equ 0x3000          ; Page Directory

;==================================================================================================
; BOOT INFO - Data passed from bootloader to kernel
;==================================================================================================
BOOT_INFO_ADDR   equ 0x7000

;==================================================================================================
; REAL MODE ENTRY POINT
;==================================================================================================
start2:
    ; Print 'S' to show stage2 loaded
    mov ah, 0x0E
    mov al, 'S'
    int 0x10

    ; Set up segment registers
    xor ax, ax
    mov ds, ax
    mov es, ax

;==================================================================================================
; E820 MEMORY MAP DETECTION
;==================================================================================================
    mov di, E820_BUF
    xor ebx, ebx
    xor bp, bp

.e820_loop:
    mov edx, 0x534D4150     ; 'SMAP' signature
    mov eax, 0xE820
    mov ecx, 24
    int 0x15
    jc .e820_done
    cmp eax, 0x534D4150
    jne .e820_done

    add di, 24
    inc bp
    test ebx, ebx
    jnz .e820_loop

.e820_done:
    ; Store entry count
    movzx eax, bp
    mov [MMAP_COUNT], eax

    ; Print 'M' to show E820 complete
    mov ah, 0x0E
    mov al, 'M'
    int 0x10

;==================================================================================================
; LOAD GDT
;==================================================================================================
    ; Copy GDT to its location
    mov si, gdt_start
    mov di, gdt_base
    mov cx, gdt_end - gdt_start
    rep movsb

    ; Load GDT register
    lgdt [gdt_descriptor]

    ; Set VGA mode
    mov ax, 0x03
    int 0x10

    mov ah, 0x0E
    mov al, 'G'
    int 0x10

;==================================================================================================
; ENABLE A20 LINE
;==================================================================================================
    in al, 0x92
    or al, 2
    out 0x92, al

    cli

;==================================================================================================
; ENTER PROTECTED MODE
;==================================================================================================
    mov eax, cr0
    or eax, 1
    mov cr0, eax

    ; Far jump to flush pipeline and enter protected mode
    jmp 0x08:pm_entry

;==================================================================================================
; DATA SECTION (Must be before [BITS 32])
;==================================================================================================
gdt_base equ 0x500

align 8
gdt_start:
    dq 0x0000000000000000    ; Null descriptor
    dq 0x00CF9A000000FFFF    ; 32-bit code segment (selector 0x08)
    dq 0x00CF92000000FFFF    ; 32-bit data segment (selector 0x10)
    dq 0x00209A0000000000    ; 64-bit code segment (selector 0x18)
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_base

message_pm:
    db 'P', 'M', '!'

;==================================================================================================
; PROTECTED MODE (32-bit)
;==================================================================================================
[BITS 32]
pm_entry:
    ; Set up segments
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov esp, EARLY_STACK_TOP

    ; Print "PM!" to VGA
    mov esi, message_pm
    mov edi, 0xB8000
    mov ecx, 3
.print_loop:
    lodsb
    mov ah, 0x0F
    stosw
    loop .print_loop

;==================================================================================================
; LOAD KERNEL
;==================================================================================================
    mov esi, 3                  ; Start at LBA sector 3
    mov edi, KERNEL_LOAD_PHYS
    mov ebx, KERNEL_SECTORS

.load_kernel_loop:
    call ata_read_sector
    inc esi
    dec ebx
    jnz .load_kernel_loop

    ; Print 'K' to show kernel loaded
    mov word [0xB800C], 0x0F4B

;==================================================================================================
; FILL BOOT INFO STRUCTURE
;==================================================================================================
    ; Kernel start (offset 0x00)
    mov dword [BOOT_INFO_ADDR + 0x00], KERNEL_LOAD_PHYS
    mov dword [BOOT_INFO_ADDR + 0x04], 0x00000000

    ; Calculate kernel size in bytes
    mov eax, KERNEL_SECTORS
    imul eax, 512               ; eax = kernel_size_bytes

    ; Kernel end (offset 0x08)
    mov edx, eax
    add edx, KERNEL_LOAD_PHYS   ; edx = kernel_phys_end
    mov dword [BOOT_INFO_ADDR + 0x08], edx
    mov dword [BOOT_INFO_ADDR + 0x0C], 0x00000000

    ; Kernel size (offset 0x10)
    mov dword [BOOT_INFO_ADDR + 0x10], eax
    mov dword [BOOT_INFO_ADDR + 0x14], 0x00000000

    ; Stack top (offset 0x18)
    mov dword [BOOT_INFO_ADDR + 0x18], KERNEL_STACK_TOP
    mov dword [BOOT_INFO_ADDR + 0x1C], 0x00000000

    ; E820 count (offset 0x20)
    mov eax, [MMAP_COUNT]
    mov dword [BOOT_INFO_ADDR + 0x20], eax

    ; Padding (offset 0x24)
    mov dword [BOOT_INFO_ADDR + 0x24], 0x00000000

    ; E820 buffer address (offset 0x28)
    mov dword [BOOT_INFO_ADDR + 0x28], E820_BUF
    mov dword [BOOT_INFO_ADDR + 0x2C], 0x00000000

    ; Page table base (offset 0x30)
    mov dword [BOOT_INFO_ADDR + 0x30], PML4_ADDR
    mov dword [BOOT_INFO_ADDR + 0x34], 0x00000000

;==================================================================================================
; BUILD PAGE TABLES FOR LONG MODE
;==================================================================================================

    ; Zero out page table memory (12 KB)
    mov edi, PML4_ADDR
    mov ecx, 3072
    xor eax, eax
    rep stosd

    ; ------------------------------------------------------------
    ; Build PML4: Entry 0 → PDPT
    ; ------------------------------------------------------------
    mov edi, PML4_ADDR
    mov eax, PDPT_ADDR | 0x03
    mov [edi], eax
    mov dword [edi + 4], 0

    ; ------------------------------------------------------------
    ; Build PDPT: Entry 0 → PD
    ; ------------------------------------------------------------
    mov edi, PDPT_ADDR
    mov eax, PD_ADDR | 0x03
    mov [edi], eax
    mov dword [edi + 4], 0

    ; ------------------------------------------------------------
    ; Build PD: map full kernel image using 2 MiB pages
    ; ------------------------------------------------------------
    mov edi, PD_ADDR                 ; PD base

    ; Map a generous window: [0 .. 16 MiB)
    mov eax, 0x00000000          ; phys_start
    mov ebx, 0x01000000          ; phys_end

    ; (eax is already aligned to 2 MiB)


    ; PD index = phys_start / 2MiB
    mov ecx, eax
    shr ecx, 21                      ; ecx = PD index

map_kernel_pages:
        cmp eax, ebx
        jge .done

        ; Build PD entry: phys | PS | RW | P
        mov edx, eax
        or edx, 0x83                 ; 0x80 = PS, 0x02 = RW, 0x01 = P

        ; Write entry into PD
        mov [edi + ecx*8], edx
        mov dword [edi + ecx*8 + 4], 0

        ; Next 2 MiB
        add eax, 0x200000
        inc ecx
        jmp map_kernel_pages

.done:

    ; ------------------------------------------------------------
    ; Mirror low mappings into higher half (PML4[511] = PML4[0])
    ; ------------------------------------------------------------
    mov edi, PML4_ADDR
    mov eax, [edi]
    mov edx, [edi + 4]

    mov ebx, 511 * 8
    add edi, ebx

    mov [edi], eax
    mov [edi + 4], edx

    ; Print 'T' to show page tables built
    mov word [0xB8006], 0x0F54

;==================================================================================================
; ENABLE LONG MODE
;==================================================================================================
    ; Load CR3 with PML4 address
    mov eax, PML4_ADDR
    mov cr3, eax

    ; Enable PAE
    mov eax, cr4
    or eax, 1 << 5
    mov cr4, eax

    ; Print 'P' to show PAE enabled
    mov word [0xB8008], 0x0F50

    ; Enable Long Mode (set EFER.LME)
    mov ecx, 0xC0000080
    rdmsr
    or eax, 1 << 8
    wrmsr

    ; Print 'E' to show LME enabled
    mov word [0xB800A], 0x0F45

;==================================================================================================
; ACTIVATE LONG MODE
;==================================================================================================
    ; Enable paging (activates long mode)
    mov eax, cr0
    or eax, 0x80000000
    mov cr0, eax

    ; Print 'Q' to show paging enabled
    mov word [0xB800E], 0x0F51

    ; Far jump to 64-bit code segment
    jmp 0x18:long_mode_entry

;==================================================================================================
; ATA DISK READ (32-bit)
;==================================================================================================
ata_read_sector:
    ; Select drive and set LBA bits 24-27
    mov dx, 0x1F6
    mov eax, esi
    shr eax, 24
    and al, 0x0F
    or al, 0xE0
    out dx, al

    ; Sector count = 1
    mov dx, 0x1F2
    mov al, 1
    out dx, al

    ; LBA bits 0-7
    mov dx, 0x1F3
    mov eax, esi
    out dx, al

    ; LBA bits 8-15
    shr eax, 8
    mov dx, 0x1F4
    out dx, al

    ; LBA bits 16-23
    shr eax, 8
    mov dx, 0x1F5
    out dx, al

    ; Send read command
    mov dx, 0x1F7
    mov al, 0x20
    out dx, al

.wait_drq:
    in al, dx
    test al, 0x08
    jz .wait_drq

    ; Read 256 words (512 bytes)
    mov dx, 0x1F0
    mov ecx, 256
    rep insw
    ret

;==================================================================================================
; LONG MODE (64-bit)
;==================================================================================================
VGA_TEXT equ 0xB8000

[BITS 64]
long_mode_entry:
    ; Clear segment registers
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax

    ; Set up 64-bit stack
    mov rsp, KERNEL_STACK_TOP

    ; Enable SSE
    mov rax, cr0
    and ax, 0xFFFB      ; Clear CR0.EM (bit 2)
    or ax, 0x0002       ; Set CR0.MP (bit 1)
    mov cr0, rax

    mov rax, cr4
    or ax, 0x0600       ; Set CR4.OSFXSR and CR4.OSXMMEXCPT (bits 9-10)
    mov cr4, rax

    ; Print '64'
    mov rdi, VGA_TEXT
    mov word [rdi + 0x10], 0x0F36
    mov word [rdi + 0x12], 0x0F34

    ; Set up boot_info pointer in RDI (even if kernel_entry ignores it now)
    mov rdi, BOOT_INFO_ADDR

    ; Jump to kernel (higher-half entry)
    mov rax, KERNEL_ENTRY
    jmp rax
