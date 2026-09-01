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

start:
    ;cli             ; <--- Disable hardware interrupts IMMEDIATELY
    ;cld             ; Clear direction flag

    ; Mask all hardware interrupts on Master and Slave PICs
    ;mov al, 0xFF
    ;out 0xA1, al                ; Slave PIC mask
    ;out 0x21, al                ; Master PIC mask

; ---JUMP TO ENTRY POINT IMMEDIATELY ---
jmp start2
;nop

;==================================================================================================
; MEMORY MAP CONSTANTS
;==================================================================================================

E820_BUF         equ 0x9000          ; E820 memory map storage buffer
MMAP_COUNT       equ 0x8FF8          ; E820 entry count (32-bit word)

KERNEL_OFFSET    equ 0xFFFFFF8000000000
KERNEL_LOAD_PHYS equ 0x00100000          ; Physical load address: 1 MiB
%include "build/kernel_info.inc"         ; Defines KERNEL_SECTORS

EARLY_STACK_TOP  equ 0x70000          ; Early stack top (grows downward)
KERNEL_STACK_TOP equ 0xC0000          ; Kernel stack top (grows downward)
KERNEL_PHYS_ENTRY equ KERNEL_LOAD_PHYS + (KERNEL_ENTRY - KERNEL_OFFSET)

; Page table base addresses (each table is one 4 KiB page)
PML4_ADDR        equ 0x1000          ; Page Map Level 4
PDPT_ADDR        equ 0x2000          ; Page Directory Pointer Table
PD_ADDR          equ 0x3000          ; Page Directory (2 MiB pages)
PDPT_KERNEL_ADDR  equ 0x4000      ; kernel PDPT
PT_KERNEL_ADDR    equ 0x5000      ; kernel PT (4 KiB pages)

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
ata_drive_sel: db 0xE0   ; Default: primary master (0xE0)

; =========================================================================
; DATA SECTION (Safe from execution because it's placed below code/loops)
; =========================================================================

align 4
kernel_dap:
    db 0x10                       ; DAP size (16 bytes)
    db 0x00                       ; Reserved
dap_sector_count:
    dw 32                         ; Read 32 sectors per chunk
dap_buffer_off:
    dw 0x0000                     ; Buffer offset
dap_buffer_seg:
    dw 0x1000                     ; Buffer segment (0x1000 * 16 = 0x10000 physical)
dap_lba_low:
    dd 16                          ; Starting LBA (Sector 16)
dap_lba_high:
    dd 0                          ; Upper 32 bits of 64-bit LBA

boot_drive:        db 0x80        ; Single definition for drive ID
sectors_remaining: dw KERNEL_SECTORS



;==================================================================================================
; REAL MODE ENTRY POINT
;==================================================================================================

start2:
    ; 1. Preserve DL (Boot drive ID passed by Stage 1 / BIOS)
    mov [boot_drive], dl

    ; 2. Ensure segment registers are 0 for real mode setup
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x5000

mov ah, 0x0E
mov al, 'A'
int 0x10

; --- ENTER UNREAL MODE ---
; Force dynamic patch of GDT descriptor base address
    mov eax, gdt_start
    mov [gdt_descriptor + 2], eax
    lgdt [gdt_descriptor]

    cli

    mov eax, cr0
    or al, 0x01                 ; Protection Enable
    mov cr0, eax

    jmp $+2                     ; Flush pipeline

    mov bx, 0x10                ; Selector 0x10 (32-bit flat data descriptor)
    mov ds, bx                  ; Load 4 GiB limits into DS descriptor cache
    mov es, bx                  ; Load 4 GiB limits into ES descriptor cache
    mov fs, bx                  ; Load 4 GiB limits into FS descriptor cache
    mov gs, bx                  ; Load 4 GiB limits into GS descriptor cache

    and al, 0xFE                ; Clear PE (Return to Real Mode)
    mov cr0, eax

    jmp $+2                     ; Flush pipeline

    ; Restore real mode segment values (0x0000) for base address calculations
    ; while preserving the expanded 4 GiB limits cached in hidden segment registers
    xor ax, ax
    mov ds, ax
    mov es, ax

    sti

; 3. Loop to read the entire kernel in 32-sector (16 KiB) chunks
; --- INITIALIZE HIGH MEMORY DESTINATION POINTER ---
    mov edi, KERNEL_LOAD_PHYS       ; EDI = 0x00100000 (1 MiB)

.read_kernel_loop:
    cmp word [sectors_remaining], 0
    je .disk_read_ok

    ; 1. Determine chunk size (max 32 sectors = 16 KiB)
    mov ax, [sectors_remaining]
    cmp ax, 32
    jbe .set_chunk_size
    mov ax, 32

.set_chunk_size:
    mov [dap_sector_count], ax

    ; 2. ALWAYS reset bounce buffer segment to 0x1000 (Physical 0x10000)
    ; This prevents dap_buffer_seg from ever advancing into Video RAM (0xA000/0xB800)
    mov word [dap_buffer_seg], 0x1000
    mov word [dap_buffer_off], 0x0000

    ; 3. Call BIOS Extended Read (INT 13h, AH=42h) into low RAM bounce buffer
    lea si, [kernel_dap]
    mov dl, [boot_drive]
    mov ah, 0x42
    int 0x13
    jc .disk_read_failed

    ; 4. Copy the loaded chunk from low RAM (0x10000) to High RAM [FS:EDI]
    ; Convert sector count to dword count (sectors * 512 / 4 = sectors * 128)
    movzx ecx, word [dap_sector_count]
    shl ecx, 7                      ; Multiply by 128 dwords (512 bytes per sector)

    mov esi, 0x00010000             ; Source physical address (0x1000:0000)

    push ds
    xor ax, ax
    mov ds, ax                      ; Ensure DS=0 for source indexing

.copy_chunk:
    a32 mov eax, [esi]              ; Load 32-bit dword from low RAM bounce buffer
    a32 mov [fs:edi], eax           ; Store 32-bit dword to high RAM (1 MiB+) using Unreal Mode FS
    add esi, 4
    add edi, 4
    loop .copy_chunk

    pop ds                          ; Restore DS

    ; 5. Update LBA and remaining sector counts
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

; BSS: PhysAddr = 0x001b4000, MemSiz = 0x0d5e188
    BSS_PHYS        equ 0x001b4000
    BSS_SIZE_DWORDS equ 0x0357862        ; 0x0d5e188 / 4


.disk_read_ok:
    ; Signal successful kernel disk read ('R')
    mov ah, 0x0E
    mov al, 'R'
    int 0x10

    ; --- ZERO BSS REGION ---
    mov edi, BSS_PHYS
    mov ecx, BSS_SIZE_DWORDS
    xor eax, eax

.zero_bss_loop:
    a32 mov [fs:edi], eax
    add edi, 4
    loop .zero_bss_loop

    mov ah, 0x0E
    mov al, 'B'
    int 0x10
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

    cmp bp, 32              ; Safety check: Limit to 32 entries to prevent overflow
    jge .e820_done

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

    ; Clear screen
    ;mov ax, 0x0003      ; INT 10h mode 3 = 80x25 text, clears screen
    ;int 0x10

; Clear interrupts before any mode switches!
    cli                     ; Mask all hardware interrupts

;==================================================================================================
; ENTER PROTECTED MODE
;==================================================================================================

    mov eax, cr0
    or  eax, 1

    ; Print '£' (Code Page 437 character 0x9C) to indicate disk failure, then halt
    ;mov ah, 0x0E
    ;mov al, 0x9C              ; 0x9C = '£' symbol in VGA video memory / CP437
    ;mov bh, 0x00              ; Page number 0
    ;mov bl, 0x07              ; Light gray on black
    ;int 0x10
    ;cli
;.error_loop:
    ;hlt
   ;jmp .error_loop

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
    dq 0x00209A0000000000   ; 0x18: 64-bit code segment (L=1, D/B=0)
    dq 0x0000920000000000   ; 64-bit data segment     (selector 0x20) <-- ADD THIS
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1   ; Limit = size of GDT - 1
    dd gdt_start                 ; Base = address of gdt_start

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

    ; 1. Zero all 3 page tables (12 KiB total = 3072 dwords)
    mov edi, PML4_ADDR
    mov ecx, 4096 / 4 * 4    ; e.g. zero PML4 + PDPT + PD + PDPT_KERNEL + PT_KERNEL
    xor eax, eax
    rep stosd

    ; 2. Set up PML4 entries
    mov edi, PML4_ADDR

    ; Identity mapping PML4[0] → PDPT_ADDR
    mov eax, PDPT_ADDR | 0x03
    mov [edi + 0   * 8], eax
    mov dword [edi + 0   * 8 + 4], 0

    ; Kernel high-half PML4[510] → PDPT_KERNEL_ADDR
    mov eax, PDPT_KERNEL_ADDR | 0x03
    mov [edi + 510 * 8], eax
    mov dword [edi + 510 * 8 + 4], 0

    ; (Optional) recursive/upper mapping in PML4[511] if you want
    mov eax, PDPT_ADDR | 0x03
    mov [edi + 511 * 8], eax
    mov dword [edi + 511 * 8 + 4], 0

    ; 3. Identity PDPT: PDPT_ADDR → PD_ADDR
    mov edi, PDPT_ADDR
    mov eax, PD_ADDR | 0x03

    mov [edi + 0 * 8], eax          ; PDPT[0] → identity PD
    mov dword [edi + 0 * 8 + 4], 0

    ; 3b. Kernel PDPT: PDPT_KERNEL_ADDR → PD_ADDR (reuse 2 MiB huge pages)
    mov edi, PDPT_KERNEL_ADDR
    mov eax, PD_ADDR | 0x03         ; same PD as identity map

    mov [edi + 0 * 8], eax          ; PDPT_KERNEL[0] → PD_ADDR
    mov dword [edi + 0 * 8 + 4], 0

    ; 4. Map 16 MiB (8 x 2 MiB Huge Pages) into PD
    mov edi, PD_ADDR
    mov eax, 0x00000000                 ; Start physical address 0x0
    mov ebx, 0x02000000                 ; 32 MiB ceiling
    xor ecx, ecx

map_kernel_pages:
    cmp eax, ebx
    jge .done_mapping_kernel

    mov edx, eax
    or  edx, 0x83                       ; Present + Writable + Huge (2 MiB)
    mov [edi + ecx * 8], edx
    mov dword [edi + ecx * 8 + 4], 0    ; Upper 32 bits explicitly 0 (NX bit = 0)

    add eax, 0x200000
    inc ecx
    jmp map_kernel_pages

.done_mapping_kernel:

    ; 4a. Map Framebuffer (0x3E000000)
    mov eax, [VBE_MODE_INFO + 40]
    and eax, 0xFFE00000
    or  eax, 0x83
    mov [edi + 496 * 8], eax
    mov dword [edi + 496 * 8 + 4], 0

    mov dword [BOOT_INFO_ADDR + 0x38], 0x3E000000
    mov dword [BOOT_INFO_ADDR + 0x3C], 0x00000000

    %if GRAPHICS_MODE_SEL == 0
        mov word [0xB8006], 0x0F54      ; Signal 'T'
    %endif

;==================================================================================================
; ENABLE LONG MODE
;==================================================================================================

    ; Register PML4 physical anchor address to CR3
    mov eax, PML4_ADDR
    mov cr3, eax

    ; Enable Physical Address Extension (PAE)
    mov eax, cr4
    or  eax, 1 << 5
    mov cr4, eax

    %if GRAPHICS_MODE_SEL == 0
        mov word [0xB8008], 0x0F50      ; Signal 'P'
    %endif

    ; Assert EFER.LME via MSR 0xC0000080
    mov ecx, 0xC0000080
    rdmsr
    or  eax, 1 << 8
    wrmsr

    %if GRAPHICS_MODE_SEL == 0
        mov word [0xB800A], 0x0F45      ; Signal 'E'
    %endif

;==================================================================================================
; ACTIVATE LONG MODE (Activate Paging Engine)
;==================================================================================================

    %if GRAPHICS_MODE_SEL == 0
        ; Signal structural paging operations ongoing ('Q')
        mov word [0xB800E], 0x0F51
    %endif

    ; Forcing CR0.PG active while LME state is asserted handles transition to 64-bit mode
    mov eax, cr0
    or  eax, 0x80000000
    mov cr0, eax

    print_far_ptr:
    mov esi, long_mode_ptr   ; ESI = address of far pointer
    mov edi, 0xb8000         ; VGA text memory
    mov ecx, 10              ; print 10 bytes

.print_loop:
    mov al, [esi]            ; load byte
    mov ah, 0x0F             ; white-on-black
    mov [edi], ax            ; write character
    inc esi
    add edi, 2               ; next VGA cell
    loop .print_loop

    ; Execute structural far jump to transition segment selector mapping into Long Mode execution
        jmp 0x18:long_mode_entry

        ; Safety net to prevent falling through into 64-bit opcodes:
    cli
    mov word [0xB8010], 0x0F58
.hang:
    hlt
    jmp .hang

;==================================================================================================
; LONG MODE (64-bit Native Execution Pipeline)
;==================================================================================================

VGA_TEXT equ 0xB8000
long_mode_ptr:
    dq long_mode_entry    ; 64-bit offset
    dw 0x18               ; 64-bit code segment selector

[BITS 64]

long_mode_entry:
    mov word [0xB8010], 0x0F2A
    mov word [0xB8020], 0x0F52

    ; Reload 64-bit data segment selectors
    mov ax, 0x20       ; 64-bit data segment selector
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov fs, ax
    mov gs, ax

    ; Implement native 64-bit stack layout (System V ABI alignment)
    ; Stack must be 16-byte aligned when calling/jumping into kernel functions.
    mov rax, 0xFFFFFF8000080000
    and rax, -16            ; Enforce strict 16-byte alignment frame
    mov rsp, rax            ; REMOVED 'sub rsp, 8' — keep stack 16-byte aligned for jmp!

    ; Assert initial SSE feature accessibility profiles: mask EM (bit 2), set MP (bit 1)
    mov rax, cr0
    and ax, 0xFFFB
    or  ax, 0x0002
    mov cr0, rax

    ; Set OSFXSR (bit 9) and OSXMMEXCPT (bit 10) for SIMD processing
    mov rax, cr4
    or  ax, 0x0600
    mov cr4, rax

    %if GRAPHICS_MODE_SEL == 0
        ; Verify long-mode execution pipeline capability ('6', '4')
        mov rdi, VGA_TEXT
        mov word [rdi + 0x12], 0x0F36
        mov word [rdi + 0x14], 0x0F34
    %endif

    ;kernel_entry equ 0xffffff80001523d0

    ; Pass boot_info structure tracking address to kernel via RDI
    mov rdi, BOOT_INFO_ADDR

    ; Jump into high-half kernel entry point definition
    mov rax, KERNEL_ENTRY

        mov word [0xB8022], 0x0F45   ; 'E'
;.efreeze: cli
    ;hlt
    ;jmp .efreeze

    jmp rax
