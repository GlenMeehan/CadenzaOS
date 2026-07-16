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

[org 0x7E00]
[bits 16]

;==================================================================================================
; MEMORY MAP CONSTANTS
;==================================================================================================

E820_BUF         equ 0x9000          ; E820 memory map storage buffer
MMAP_COUNT       equ 0x8FF8          ; E820 entry count (32-bit word)

KERNEL_OFFSET    equ 0xFFFFFFFF80000000
KERNEL_LOAD_PHYS equ 0x00100000          ; Physical load address: 1 MiB
%include "build/kernel_info.inc"         ; Defines KERNEL_SECTORS

EARLY_STACK_TOP  equ 0x70000          ; Early stack top (grows downward)
KERNEL_STACK_TOP equ 0xC0000          ; Kernel stack top (grows downward)

; Page table base addresses (each table is one 4 KiB page)
PML4_ADDR        equ 0x1000          ; Page Map Level 4
PDPT_ADDR        equ 0x2000          ; Page Directory Pointer Table
PD_ADDR          equ 0x3000          ; Page Directory (2 MiB pages)

VBE_MODE_INFO    equ 0xA000         ; Safe buffer to hold VBE mode details temporarily

; GRAPHICS CONFIGURATION
; 0 = Legacy VGA Text Mode (80x25)
; 1 = VESA Graphics Mode (1024x768x32)
GRAPHICS_MODE_SEL equ 1

;==================================================================================================
; BOOT INFO STRUCTURE
; Passed from Stage 2 to the kernel via RDI.
; Layout (all fields are 64-bit / 8-byte aligned):
;   0x00  kernel_phys_start
;   0x08  kernel_phys_end
;   0x10  kernel_size_bytes
;   0x18  kernel_stack_top
;   0x20  e820_entry_count   (32-bit, zero-extended)
;   0x24  graphics_mode      (0 = VGA, 1 = VESA)
;   0x28  e820_buffer_addr
;   0x30  pml4_addr
;   0x38  framebuffer_addr   (64-bit physical pointer to VESA LFB)
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

    ; Set up real-mode stack safely below our data structures
    xor ax, ax
    mov ss, ax
    mov sp, 0x5000   ; well below VBE buffer and BOOT_INFO
                                            ; Combined physical stack top: 0x9FFFF

    ; Restore zero-base for data operations
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
    mov ecx, 24              ; Each E820 entry is 24 bytes
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
; GRAPHICS INITIALIZATION (TOGGLEABLE)
;==================================================================================================

%if GRAPHICS_MODE_SEL == 1
        ; --- ATTEMPT VESA GRAPHICS INIT ---
        mov ax, 0x4F01
        mov cx, 0x0115           ; Query: 1024x768x32bpp (no LFB bit for query)
        mov di, VBE_MODE_INFO
        int 0x10
        cmp al, 0x4F             ; Check if VBE is supported natively
        jne .vesa_fail

        mov ax, 0x4F02
        mov bx, 0x4115           ; Set: 1024x768x32bpp + LFB bit
        int 0x10
        cmp al, 0x4F             ; Verify mode successfully engaged
        jne .vesa_fail

        jmp .graphics_done

    .vesa_fail:
        jmp $                    ; Hard hang if VESA requested but configuration fails
    %else
        ; --- FALLBACK TO LEGACY VGA TEXT MODE ---
        mov ax, 0x03
        int 0x10
    %endif

.graphics_done:
    ; Signal Real-Mode Display Configuration Complete
    mov ah, 0x0E
    %if GRAPHICS_MODE_SEL == 1
        mov al, 'V'              ; 'V' = VESA active
    %else
        mov al, 'G'              ; 'G' = Legacy VGA active
    %endif
    int 0x10

;==================================================================================================
; RESET SEGMENTS POST-BIOS CALLS
;==================================================================================================
    xor ax, ax
    mov ds, ax
    mov es, ax

    ; Signal GDT structure copies finished ('G')
    ;This section commented out as GDT now moved to below ENABLE A20
    ;mov ah, 0x0E
    ;mov al, 'G'
    ;int 0x10

;==================================================================================================
; ENABLE A20 LINE
;==================================================================================================

    in  al, 0x92
    or  al, 2
    out 0x92, al

    cli                     ; Disable hardware interrupts before PM transition

;==================================================================================================
; LOAD AND INSTALL GDT
;==================================================================================================

    ; Copy GDT data to its fixed physical location
    mov si, gdt_start
    mov di, gdt_base
    mov cx, gdt_end - gdt_start
    rep movsb

    ; Build a rock-solid GDT descriptor right on the stack
    ; This bypasses relative label calculations entirely
    push dword 0x0500                   ; Push physical base pointer (gdt_base)
    push word (gdt_end - gdt_start - 1) ; Push GDT size limit (0x2F)

    mov bx, sp                          ; Point BX to our stack frame
    lgdt [bx]                           ; Load GDTR directly from stack memory
    add sp, 6                           ; Clean up the stack frame

;==================================================================================================
; ENTER PROTECTED MODE
;==================================================================================================

    mov eax, cr0
    or  eax, 1
    mov cr0, eax

    ; Far jump flushes prefetch pipeline and binds CS to 32-bit segment descriptor
    jmp 0x08:pm_entry

;==================================================================================================
; DATA SECTION (must remain before [BITS 32] boundary)
;==================================================================================================

gdt_base equ 0x500          ; Fixed physical address target for active GDT

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
; PROTECTED MODE (32-bit Execution Frame)
;==================================================================================================

[BITS 32]
pm_entry:
    ; Bind structural data segments to target 32-bit data descriptor
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov esp, EARLY_STACK_TOP

    ; Print logs to 0xB8000 ONLY when legacy VGA text layout is active
    %if GRAPHICS_MODE_SEL == 0
        mov esi, message_pm
        mov edi, 0xB8000
        mov ecx, 3
    .print_loop:
        lodsb
        mov ah, 0x0F            ; Attribute: white text, black background
        stosw
        loop .print_loop
    %endif

;==================================================================================================
; LOAD KERNEL FROM DISK
;==================================================================================================

    mov esi, 3              ; Start LBA (sector 3 — after MBR and Stage 2 stack layout)
    mov edi, KERNEL_LOAD_PHYS
    mov ebx, KERNEL_SECTORS

.load_kernel_loop:
    call ata_read_sector
    inc  esi                ; Advance target disk position
    dec  ebx
    jnz  .load_kernel_loop

    %if GRAPHICS_MODE_SEL == 0
        ; Signal kernel payload extraction completed successfully ('K')
        mov word [0xB800C], 0x0F4B
    %endif

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

    ; graphics_mode identifier (offset 0x24 - overrides legacy alignment padding)
    mov dword [BOOT_INFO_ADDR + 0x24], GRAPHICS_MODE_SEL

    ; e820_buffer_addr (offset 0x28)
    mov dword [BOOT_INFO_ADDR + 0x28], E820_BUF
    mov dword [BOOT_INFO_ADDR + 0x2C], 0x00000000

    ; pml4_addr (offset 0x30)
    mov dword [BOOT_INFO_ADDR + 0x30], PML4_ADDR
    mov dword [BOOT_INFO_ADDR + 0x34], 0x00000000

    ; framebuffer_addr (offset 0x38)
    mov eax, [VBE_MODE_INFO + 40]   ; Read linear framebuffer physical pointer from VBE struct
    mov dword [BOOT_INFO_ADDR + 0x38], eax
    mov dword [BOOT_INFO_ADDR + 0x3C], 0x00000000

    ; fb_stride — bytes per scan line (offset 0x40)
    movzx eax, word [VBE_MODE_INFO + 0x10]
    mov dword [BOOT_INFO_ADDR + 0x40], eax
    mov dword [BOOT_INFO_ADDR + 0x44], 0

    ; fb_width — pixels per row (offset 0x48)
    movzx eax, word [VBE_MODE_INFO + 0x12]
    mov dword [BOOT_INFO_ADDR + 0x48], eax
    mov dword [BOOT_INFO_ADDR + 0x4C], 0

    ; fb_height — pixels per column (offset 0x50)
    movzx eax, word [VBE_MODE_INFO + 0x14]
    mov dword [BOOT_INFO_ADDR + 0x50], eax
    mov dword [BOOT_INFO_ADDR + 0x54], 0

    ; fb_bpp — bits per pixel (offset 0x58)
    movzx eax, byte [VBE_MODE_INFO + 0x19]
    mov dword [BOOT_INFO_ADDR + 0x58], eax
    mov dword [BOOT_INFO_ADDR + 0x5C], 0

;==================================================================================================
; BUILD PAGE TABLES FOR LONG MODE
; Layout: PML4[0] → PDPT[0] → PD → 2 MiB pages covering [0 .. 16 MiB)
;==================================================================================================

    ; Zero all three page tables safely (12 KiB total size = 3072 dwords)
    mov edi, PML4_ADDR
    mov ecx, 3072
    xor eax, eax
    rep stosd

    ; PML4[0] → PDPT  (present + writable)
    mov edi, PML4_ADDR
    mov eax, PDPT_ADDR | 0x03
    mov [edi], eax
    mov dword [edi + 4], 0

    ; === PDPT[510] → PD (Maps 0xFFFFFFFF80000000 higher-half base) ===
    mov eax, PD_ADDR | 0x03
    mov [edi + 510 * 8], eax
    mov dword [edi + 510 * 8 + 4], 0

    ; PDPT[0] → PD  (present + writable)
    mov edi, PDPT_ADDR
    mov eax, PD_ADDR | 0x03
    mov [edi], eax
    mov dword [edi + 4], 0

    ; PD: Map low-level execution domain [0 .. 16 MiB) using 2 MiB identity mappings
    mov edi, PD_ADDR
    mov eax, 0x00000000     ; Tracked physical mapping base address
    mov ebx, 0x40000000     ; 1GB loop ceiling constraint (keeps logic 32-bit uniform)
    mov ecx, eax
    shr ecx, 21              ; Initialize base index value (phys_addr / 2 MiB)

map_kernel_pages:
    cmp eax, ebx
    jge .done_mapping_kernel

    mov edx, eax
    or  edx, 0x83           ; Configuration parameters: Huge Page (2 MiB) | Writable | Present
    mov [edi + ecx*8],     edx
    mov dword [edi + ecx*8 + 4], 0

    add eax, 0x200000       ; Increment tracked resource window by 2 MiB
    inc ecx
    jmp map_kernel_pages

.done_mapping_kernel:

    ; === SAFE FRAMEBUFFER MAP INTO THE FIRST 1GB ===
    ; Fetch the physical framebuffer address from the BIOS structure
    mov eax, [VBE_MODE_INFO + 40]

    ; Force the physical page flags (Mask alignment bits, set Huge, Writable, Present)
    and eax, 0xFFE00000
    or  eax, 0x83

    ; Map it directly to index 496 (Virtual address 0x3E000000)
    ; This keeps the write within the boundaries of our 4KB Page Directory.
    mov edi, PD_ADDR
    mov [edi + 496*8], eax
    mov dword [edi + 496*8 + 4], 0

    ; Pass this virtual window address to the BootInfo struct instead of the raw physical one
    mov dword [BOOT_INFO_ADDR + 0x38], 0x3E000000
    mov dword [BOOT_INFO_ADDR + 0x3C], 0x00000000

.done:
    ; Mirror PML4[0] into PML4[511] to establish high-half memory visibility
    mov edi, PML4_ADDR
    mov eax, [edi]
    mov edx, [edi + 4]
    mov ebx, 511 * 8
    add edi, ebx
    mov [edi],     eax
    mov [edi + 4], edx

    ; === ADD THIS: Mirror PDPT[0] into PDPT[510] and PDPT[511] ===
    mov edi, PDPT_ADDR
    mov eax, [edi]                  ; Fetch PD_ADDR | 0x03
    mov edx, [edi + 4]

    ; Copy to PDPT[510]
    mov [edi + 510 * 8], eax
    mov [edi + 510 * 8 + 4], edx

    ; Copy to PDPT[511]
    mov [edi + 511 * 8], eax
    mov [edi + 511 * 8 + 4], edx

    %if GRAPHICS_MODE_SEL == 0
        ; Signal completion of page tables ('T')
        mov word [0xB8006], 0x0F54
    %endif

;==================================================================================================
; ENABLE LONG MODE
;==================================================================================================

    ; Register PML4 physical anchor address to CR3
    mov eax, PML4_ADDR
    mov cr3, eax

    ; Enable Physical Address Extension (PAE) — prerequisite constraint for IA32-e
    mov eax, cr4
    or  eax, 1 << 5
    mov cr4, eax

    %if GRAPHICS_MODE_SEL == 0
        ; Signal PAE setup achieved ('P')
        mov word [0xB8008], 0x0F50
    %endif

    ; Assert EFER.LME (Long Mode Enable) control bit via MSR 0xC0000080
    mov ecx, 0xC0000080
    rdmsr
    or  eax, 1 << 8
    wrmsr

    %if GRAPHICS_MODE_SEL == 0
        ; Signal LME phase confirmation achieved ('E')
        mov word [0xB800A], 0x0F45
    %endif

;==================================================================================================
; ACTIVATE LONG MODE (Activate Paging Engine)
;==================================================================================================

    ; Forcing CR0.PG active while LME state is asserted handles transition to 64-bit mode
    mov eax, cr0
    or  eax, 0x80000000
    mov cr0, eax

    %if GRAPHICS_MODE_SEL == 0
        ; Signal structural paging operations ongoing ('Q')
        mov word [0xB800E], 0x0F51
    %endif

    ; Execute structural far jump to transition segment selector mapping into Long Mode execution
    jmp 0x18:long_mode_entry

;==================================================================================================
; ATA PIO SECTOR READ (32-bit Protected Mode Utility function)
; Reads one 512-byte sector from LBA in ESI into memory at EDI.
;==================================================================================================

ata_read_sector:
    ; Drive selection: Master unit configuration, parse LBA target bits 24-27
    mov dx, 0x1F6
    mov eax, esi
    shr eax, 24
    and al, 0x0F
    or  al, 0xE0
    out dx, al

    ; Command block size definition: 1 target sector
    mov dx, 0x1F2
    mov al, 1
    out dx, al

    ; Map sequential LBA components across targeted controller IO registries
    mov dx, 0x1F3
    mov eax, esi
    out dx, al              ; Bits 0-7

    shr eax, 8
    mov dx, 0x1F4
    out dx, al              ; Bits 8-15

    shr eax, 8
    mov dx, 0x1F5
    out dx, al              ; Bits 16-23

    ; Transmit operational instruction sequence (READ SECTORS = 0x20)
    mov dx, 0x1F7
    mov al, 0x20
    out dx, al

.wait_drq:
    in  al, dx
    test al, 0x08           ; Query operational status for DRQ data readiness flag
    jz  .wait_drq

    ; Process data extraction sequence: pull 256 structural words (512 bytes) into [EDI]
    mov dx, 0x1F0
    mov ecx, 256
    rep insw
    ret

;==================================================================================================
; LONG MODE (64-bit Native Execution Pipeline)
;==================================================================================================

VGA_TEXT equ 0xB8000

[BITS 64]
long_mode_entry:
    ; Zero out active fallback tracking descriptor spaces (Flat layout invariant)
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax

    ; Implement native 64-bit stack layout conforming to System V ABI alignment requirements
    mov rax, 0xFFFFFF8000080000
    and rax, -16            ; Clamp allocation to clean 16-byte boundary frame
    mov rsp, rax
    sub rsp, 8              ; Standard alignment offset footprint reservation

    ; Assert initial SSE feature accessibility profiles: mask EM (bit 2), set MP (bit 1)
    mov rax, cr0
    and ax, 0xFFFB
    or  ax, 0x0002
    mov cr0, rax

    ; Set OSFXSR (bit 9) and OSXMMEXCPT (bit 10) to register robust modern SIMD processing
    mov rax, cr4
    or  ax, 0x0600
    mov cr4, rax

    %if GRAPHICS_MODE_SEL == 0
        ; Verify long-mode execution pipeline capability ('6', '4')
        mov rdi, VGA_TEXT
        mov word [rdi + 0x10], 0x0F36
        mov word [rdi + 0x12], 0x0F34
    %endif

    ; Pass boot_info structure tracking address to our target kernel environment via RDI register
    mov rdi, BOOT_INFO_ADDR

    ; Final jump into high-half kernel entry point definition
    mov rax, KERNEL_ENTRY
    jmp rax
