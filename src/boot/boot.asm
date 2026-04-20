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

    ; Load Stage 2 from disk using BIOS interrupt 0x13 (CHS read)
    mov ah, 0x02    ; Function: read sectors
    mov al, 20      ; Number of sectors to read (20 × 512 = 10 KiB)
    mov bx, 0x7E00  ; Destination: immediately after this bootsector in memory
    mov ch, 0       ; Cylinder 0
    mov cl, 2       ; Sector 2 (sector numbering is 1-based; sector 1 = this MBR)
    mov dh, 0       ; Head 0
    mov dl, 0x80    ; Drive 0x80 = first hard disk
    int 0x13        ; BIOS disk read

    jc  .disk_error ; Carry flag set = read failed

    jmp 0x7E00      ; Hand off to Stage 2

.disk_error:
    ; Disk read failed — halt rather than jumping into undefined memory
    hlt
    jmp .disk_error ; Loop in case of spurious NMI waking the CPU

; Pad to 510 bytes, then write the MBR boot signature
times 510-($-$$) db 0
dw 0xAA55
