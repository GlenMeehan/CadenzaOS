; src/boot/boot.asm
;
; Stage 1 Bootloader
; ------------------
; Loaded by the BIOS at 0x7C00 (exactly 512 bytes, MBR position).
; Responsibility: load Stage 2 from disk into memory and jump to it.
;
; Memory layout after this runs:
;   0x7C00  This code (512 bytes, 1 sector)
;   0x7E00  Stage 2 (loaded below, 20 sectors = 10 KiB)
;
; BIOS assumptions:
;   • Drive number is passed in DL by the BIOS (we override it to 0x80)
;   • CHS geometry: cylinder 0, head 0, sector 2 (sectors are 1-indexed)

; src/boot/boot.asm
[org 0x7C00]
[bits 16]

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    mov [boot_drive], dl

    mov ah, 0x0E
    mov al, '1'
    int 0x10

    ; Check INT 13h extensions are present
    mov ah, 0x41
    mov bx, 0x55AA
    mov dl, [boot_drive]
    int 0x13
    jc .no_extensions
    cmp bx, 0xAA55
    jne .no_extensions

    mov ah, 0x0E
    mov al, '2'
    int 0x10

    ; Extended LBA read of Stage 2 (20 sectors, starting at LBA 1) into 0x0000:0x7E00
    mov si, dap
    mov dl, [boot_drive]
    mov ah, 0x42
    int 0x13
    jc .disk_error

    mov ah, 0x0E
    mov al, '3'
    int 0x10

    jmp 0x7E00

.no_extensions:
    mov ah, 0x0E
    mov al, 'X'
    int 0x10
    jmp .hang

.disk_error:
    mov ah, 0x0E
    mov al, 'E'
    int 0x10

.hang:
    hlt
    jmp .hang

boot_drive: db 0

align 4
dap:
    db 0x10          ; DAP size
    db 0x00          ; reserved
    dw 20            ; sectors to read (stage2 = 20 sectors)
    dw 0x7E00        ; destination offset
    dw 0x0000        ; destination segment
    dd 1             ; starting LBA (sector 1 — right after this boot sector)
    dd 0             ; upper 32 bits of LBA

times 510-($-$$) db 0
dw 0xAA55
