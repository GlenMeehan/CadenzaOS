; src/stage2/stage2.asm
;
; Stage 2 Bootloader — Real Mode → Protected Mode → Long Mode → Kernel
; ---------------------------------------------------------------------
; Loaded by Stage 1 at 0x7E00.
; Responsibilities:
;   • Detect physical memory map via BIOS E820
;   • Load the kernel from disk (ATA PIO) into physical memory at 1 MiB
;   • Build a minimal 4-level page table (identity + higher-half mirror)
;   • Transition CPU: Real Mode → Protected Mode → Long Mode
;   • Enable SSE and jump to the kernel entry point
;
; Boot progress characters are written to VGA text mode as each phase
; completes: S M G (real mode) → PM! (protected mode) → K T P E Q 64

[org 0x7E00]
[bits 16]

;==================================================================================================
; MEMORY MAP CONSTANTS
;==================================================================================================

E820_BUF         equ 0x9000          ; E820 memory map storage buffer
MMAP_COUNT       equ 0x8FF8          ; E820 entry count (32-bit word)

KERNEL_OFFSET    equ 0xFFFFFFFF80000000
KERNEL_LOAD_PHYS equ 0x00100000      ; Physical load address: 1 MiB
%include "build/kernel_info.inc"     ; Defines KERNEL_SECTORS

EARLY_STACK_TOP  equ 0x70000         ; Early stack top (grows downward)
KERNEL_STACK_TOP equ 0xC0000         ; Kernel stack top (grows downward)

; Page table base addresses (each table is one 4 KiB page)
PML4_ADDR        equ 0x1000          ; Page Map Level 4
PDPT_ADDR        equ 0x2000          ; Page Directory Pointer Table
PD_ADDR          equ 0x3000          ; Page Directory (2 MiB pages)

;==================================================================================================
; BOOT INFO STRUCTURE
; Passed from Stage 2 to the kernel via RDI.
; Layout (all fields are 64-bit / 8-byte aligned):
;   0x00  kernel_phys_start
;   0x08  kernel_phys_end
;   0x10  kernel_size_bytes
;   0x18  kernel_stack_top
;   0x20  e820_entry_count   (32-bit, zero-extended)
;   0x24  padding
;   0x28  e820_buffer_addr
;   0x30  pml4_addr
;==================================================================================================

BOOT_INFO_ADDR   equ 0x7000

;==================================================================================================
; REAL MODE ENTRY POINT
;==================================================================================================

start2:
    ; Signal Stage 2 is alive ('S' via BIOS teletype)
    mov ah, 0x0E
    mov al, 'S'
    int 0x10

    ; Clear segment registers
    xor ax, ax
    mov ds, ax
    mov es, ax

;==================================================================================================
; E820 MEMORY MAP DETECTION
;==================================================================================================

    mov di, E820_BUF
    xor ebx, ebx
    xor bp, bp              ; bp = entry count

.e820_loop:
    mov edx, 0x534D4150     ; 'SMAP' signature required by BIOS
    mov eax, 0xE820
    mov ecx, 24             ; Each E820 entry is 24 bytes
    int 0x15
    jc  .e820_done          ; Carry set = end of list or error
    cmp eax, 0x534D4150     ; BIOS must echo 'SMAP' on success
    jne .e820_done

    add di, 24
    inc bp
    test ebx, ebx           ; ebx = 0 means this was the last entry
    jnz .e820_loop

.e820_done:
    movzx eax, bp
    mov [MMAP_COUNT], eax   ; Store final entry count

    ; Signal E820 complete ('M')
    mov ah, 0x0E
    mov al, 'M'
    int 0x10

;==================================================================================================
; LOAD AND INSTALL GDT
;==================================================================================================

    ; Copy GDT data to its fixed physical location
    mov si, gdt_start
    mov di, gdt_base
    mov cx, gdt_end - gdt_start
    rep movsb

    ; Install the GDT
    lgdt [gdt_descriptor]

    ; Switch VGA to 80×25 text mode (clears screen)
    mov ax, 0x03
    int 0x10

    ; Signal GDT loaded ('G')
    mov ah, 0x0E
    mov al, 'G'
    int 0x10

;==================================================================================================
; ENABLE A20 LINE
;==================================================================================================

    in  al, 0x92
    or  al, 2
    out 0x92, al

    cli                     ; Disable interrupts before entering protected mode

;==================================================================================================
; ENTER PROTECTED MODE
;==================================================================================================

    mov eax, cr0
    or  eax, 1
    mov cr0, eax

    ; Far jump flushes the prefetch queue and loads CS with the 32-bit code selector
    jmp 0x08:pm_entry

;==================================================================================================
; DATA SECTION (must remain before [BITS 32])
;==================================================================================================

gdt_base equ 0x500          ; Fixed physical address for the installed GDT

align 8
gdt_start:
    dq 0x0000000000000000   ; Null descriptor         (selector 0x00)
    dq 0x00CF9A000000FFFF   ; 32-bit code segment     (selector 0x08)
    dq 0x00CF92000000FFFF   ; 32-bit data segment     (selector 0x10)
    dq 0x00209A0000000000   ; 64-bit code segment     (selector 0x18)
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
    ; Point all data segments at the 32-bit data descriptor
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov esp, EARLY_STACK_TOP

    ; Print "PM!" to VGA text buffer (white on black)
    mov esi, message_pm
    mov edi, 0xB8000
    mov ecx, 3
.print_loop:
    lodsb
    mov ah, 0x0F            ; Attribute: white text, black background
    stosw
    loop .print_loop

;==================================================================================================
; LOAD KERNEL FROM DISK
;==================================================================================================

    mov esi, 3              ; Start LBA (sector 3 — after MBR and Stage 2)
    mov edi, KERNEL_LOAD_PHYS
    mov ebx, KERNEL_SECTORS

.load_kernel_loop:
    call ata_read_sector
    inc  esi                ; Advance to next LBA
    dec  ebx
    jnz  .load_kernel_loop

    ; Signal kernel loaded ('K')
    mov word [0xB800C], 0x0F4B

;==================================================================================================
; FILL BOOT INFO STRUCTURE
;==================================================================================================

    ; kernel_phys_start (offset 0x00)
    mov dword [BOOT_INFO_ADDR + 0x00], KERNEL_LOAD_PHYS
    mov dword [BOOT_INFO_ADDR + 0x04], 0x00000000

    ; kernel_size_bytes = KERNEL_SECTORS × 512
    mov eax, KERNEL_SECTORS
    imul eax, 512

    ; kernel_phys_end (offset 0x08)
    mov edx, eax
    add edx, KERNEL_LOAD_PHYS
    mov dword [BOOT_INFO_ADDR + 0x08], edx
    mov dword [BOOT_INFO_ADDR + 0x0C], 0x00000000

    ; kernel_size_bytes (offset 0x10)
    mov dword [BOOT_INFO_ADDR + 0x10], eax
    mov dword [BOOT_INFO_ADDR + 0x14], 0x00000000

    ; kernel_stack_top (offset 0x18)
    mov dword [BOOT_INFO_ADDR + 0x18], KERNEL_STACK_TOP
    mov dword [BOOT_INFO_ADDR + 0x1C], 0x00000000

    ; e820_entry_count (offset 0x20)
    mov eax, [MMAP_COUNT]
    mov dword [BOOT_INFO_ADDR + 0x20], eax

    ; padding (offset 0x24)
    mov dword [BOOT_INFO_ADDR + 0x24], 0x00000000

    ; e820_buffer_addr (offset 0x28)
    mov dword [BOOT_INFO_ADDR + 0x28], E820_BUF
    mov dword [BOOT_INFO_ADDR + 0x2C], 0x00000000

    ; pml4_addr (offset 0x30)
    mov dword [BOOT_INFO_ADDR + 0x30], PML4_ADDR
    mov dword [BOOT_INFO_ADDR + 0x34], 0x00000000

;==================================================================================================
; BUILD PAGE TABLES FOR LONG MODE
; Layout: PML4[0] → PDPT[0] → PD → 2 MiB pages covering [0 .. 16 MiB)
; The same PDPT is mirrored into PML4[511] for the higher-half kernel window.
;==================================================================================================

    ; Zero all three page tables (12 KiB = 3072 dwords)
    mov edi, PML4_ADDR
    mov ecx, 3072
    xor eax, eax
    rep stosd

    ; PML4[0] → PDPT  (present + writable)
    mov edi, PML4_ADDR
    mov eax, PDPT_ADDR | 0x03
    mov [edi], eax
    mov dword [edi + 4], 0

    ; PDPT[0] → PD  (present + writable)
    mov edi, PDPT_ADDR
    mov eax, PD_ADDR | 0x03
    mov [edi], eax
    mov dword [edi + 4], 0

    ; PD: map [0 .. 16 MiB) using 2 MiB pages (PS | RW | P = 0x83)
    mov edi, PD_ADDR
    mov eax, 0x00000000     ; Physical start address
    mov ebx, 0x40000000     ; Physical end address (1GB ceiling — maps 512 entries)
    mov ecx, eax
    shr ecx, 21             ; Initial PD index (phys_addr / 2 MiB)

map_kernel_pages:
    cmp eax, ebx
    jge .done

    mov edx, eax
    or  edx, 0x83                       ; PS (2 MiB page) | RW | Present
    mov [edi + ecx*8],     edx
    mov dword [edi + ecx*8 + 4], 0

    add eax, 0x200000                   ; Advance by 2 MiB
    inc ecx
    jmp map_kernel_pages

.done:
    ; Mirror PML4[0] into PML4[511] so the higher-half virtual window resolves
    ; to the same PDPT (and therefore the same physical pages)
    mov edi, PML4_ADDR
    mov eax, [edi]
    mov edx, [edi + 4]
    mov ebx, 511 * 8
    add edi, ebx
    mov [edi],     eax
    mov [edi + 4], edx

    ; Signal page tables built ('T')
    mov word [0xB8006], 0x0F54

;==================================================================================================
; ENABLE LONG MODE
;==================================================================================================

    ; Load CR3 with the PML4 physical address
    mov eax, PML4_ADDR
    mov cr3, eax

    ; Enable Physical Address Extension (PAE) — required for long mode
    mov eax, cr4
    or  eax, 1 << 5
    mov cr4, eax

    ; Signal PAE enabled ('P')
    mov word [0xB8008], 0x0F50

    ; Set EFER.LME (Long Mode Enable) via MSR 0xC0000080
    mov ecx, 0xC0000080
    rdmsr
    or  eax, 1 << 8
    wrmsr

    ; Signal LME set ('E')
    mov word [0xB800A], 0x0F45

;==================================================================================================
; ACTIVATE LONG MODE (enable paging)
;==================================================================================================

    ; Setting CR0.PG while LME is set activates long mode
    mov eax, cr0
    or  eax, 0x80000000
    mov cr0, eax

    ; Signal paging enabled ('Q')
    mov word [0xB800E], 0x0F51

    ; Far jump into the 64-bit code segment — CPU is now in long mode
    jmp 0x18:long_mode_entry

;==================================================================================================
; ATA PIO SECTOR READ (32-bit helper)
; Reads one 512-byte sector from LBA in ESI into memory at EDI.
; EDI is advanced by 512 bytes by the `rep insw` instruction.
;==================================================================================================

ata_read_sector:
    ; Select primary master drive; load LBA bits 24-27
    mov dx, 0x1F6
    mov eax, esi
    shr eax, 24
    and al, 0x0F
    or  al, 0xE0
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

    ; Issue READ SECTORS command (0x20)
    mov dx, 0x1F7
    mov al, 0x20
    out dx, al

.wait_drq:
    in  al, dx
    test al, 0x08           ; DRQ bit — drive ready to transfer data
    jz  .wait_drq

    ; Read 256 words (512 bytes) into [EDI]; EDI advances automatically
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
    ; Clear all data segment registers (not used in 64-bit flat model)
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax

    ; Set up the 64-bit stack (16-byte aligned per System V ABI)
    mov rax, 0xFFFFFF8000080000
    and rax, -16            ; Align down to 16-byte boundary
    mov rsp, rax
    sub rsp, 8              ; Reserve space for the implicit return address slot

    ; Enable SSE: clear CR0.EM (bit 2), set CR0.MP (bit 1)
    mov rax, cr0
    and ax, 0xFFFB
    or  ax, 0x0002
    mov cr0, rax

    ; Set CR4.OSFXSR (bit 9) and CR4.OSXMMEXCPT (bit 10)
    mov rax, cr4
    or  ax, 0x0600
    mov cr4, rax

    ; Signal 64-bit mode active ('6', '4')
    mov rdi, VGA_TEXT
    mov word [rdi + 0x10], 0x0F36
    mov word [rdi + 0x12], 0x0F34

    ; Pass boot_info pointer to kernel in RDI (first argument per System V ABI)
    mov rdi, BOOT_INFO_ADDR

    ; Jump to the higher-half kernel entry point
    mov rax, KERNEL_ENTRY
    jmp rax
