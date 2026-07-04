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

[org 0x7C00]
[bits 16]
    ; Save the boot drive number the BIOS passed us in DL
    mov [boot_drive], dl

    ; Load Stage 2 from disk using BIOS interrupt 0x13 (CHS read)
    mov ah, 0x02
    mov al, 20
    mov bx, 0x7E00
    mov ch, 0
    mov cl, 2
    mov dh, 0
    mov dl, [boot_drive]   ; Use BIOS-provided drive number, not hardcoded 0x80
    int 0x13
    jc  .disk_error
    jmp 0x7E00

.disk_error:
    hlt
    jmp .disk_error

boot_drive: db 0

times 510-($-$$) db 0
dw 0xAA55
