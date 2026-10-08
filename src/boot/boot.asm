; ==============================================================================
; File: src/boot/boot.asm
; Description: Stage 1 Master Boot Record (MBR) Bootloader
;
; Memory Layout:
;   0x7C00 - 0x7DFF : Stage 1 Bootloader (512 bytes, Sector 0)
;   0x7E00 - 0xA5FF : Stage 2 Loaded Image (20 sectors = 10 KiB)
;   0x7C00          : Top of stack (grows downwards towards 0x0000)
; ==============================================================================

[org 0x7C00]        ; BIOS loads MBR at physical address 0x7C00
[bits 16]           ; Operate in 16-bit Real Mode

start:
    ; --------------------------------------------------------------------------
    ; 1. Environment & Register Setup
    ; --------------------------------------------------------------------------
    cli             ; Clear interrupts while reconfiguring segments and stack

    xor ax, ax      ; Zero out AX register (AX = 0x0000)
    mov ds, ax      ; Data Segment = 0x0000
    mov es, ax      ; Extra Segment = 0x0000
    mov ss, ax      ; Stack Segment = 0x0000
    mov sp, 0x7C00  ; Stack Pointer set to 0x7C00 (grows down, protecting MBR code)

    sti             ; Re-enable interrupts once stack is safe

    ; Save boot drive number passed in DL by BIOS (e.g., 0x80 for 1st hard disk)
    mov [boot_drive], dl

    ; Debug Checkpoint '1': Start of execution
    mov ah, 0x0E    ; INT 10h AH=0Eh: Teletype Output
    mov al, '1'     ; Character to display
    int 0x10        ; Call BIOS Video Services

    ; --------------------------------------------------------------------------
    ; 2. Verify BIOS LBA Extensions Support
    ; --------------------------------------------------------------------------
    mov ah, 0x41    ; INT 13h AH=41h: Check Extension Present
    mov bx, 0x55AA  ; Magic number requirement for INT 13h extensions check
    mov dl, [boot_drive]
    int 0x13        ; Call BIOS Disk Services

    jc .no_extensions ; Carry flag set -> extensions not supported
    cmp bx, 0xAA55    ; BX must be modified to 0xAA55 if extensions exist
    jne .no_extensions

    ; Debug Checkpoint '2': LBA Extensions verified
    mov ah, 0x0E
    mov al, '2'
    int 0x10

    ; --------------------------------------------------------------------------
    ; 3. Load Stage 2 from Disk via Extended Read
    ; --------------------------------------------------------------------------
    mov si, dap     ; DS:SI points to Disk Address Packet (DAP) struct
    mov dl, [boot_drive]
    mov ah, 0x42    ; INT 13h AH=42h: Extended Read Sectors from Drive
    int 0x13
    jc .disk_error  ; Carry flag set -> read failure

    ; Debug Checkpoint '3': Stage 2 successfully loaded into memory
    mov ah, 0x0E
    mov al, '3'
    int 0x10

    ; --------------------------------------------------------------------------
    ; 4. Execution Transfer
    ; --------------------------------------------------------------------------
    jmp 0x7E00      ; Transfer control to Stage 2 load location

; ------------------------------------------------------------------------------
; Error Handlers & Infinite Loop
; ------------------------------------------------------------------------------
.no_extensions:
    mov ah, 0x0E
    mov al, 'X'     ; Display 'X' if INT 13h extensions are unavailable
    int 0x10
    jmp .hang

.disk_error:
    mov ah, 0x0E
    mov al, 'E'     ; Display 'E' on disk read failure
    int 0x10

.hang:
    hlt             ; Halt CPU until next interrupt
    jmp .hang       ; Infinite loop if wake event occurs

; ------------------------------------------------------------------------------
; Data Storage & Structures
; ------------------------------------------------------------------------------
boot_drive: db 0    ; Holds drive identifier passed by BIOS

align 4
; Disk Address Packet (DAP) structure for INT 13h AH=42h
dap:
    db 0x10         ; Packet size (16 bytes = 0x10)
    db 0x00         ; Reserved (must be 0)
    dw 20           ; Number of sectors to read (20 sectors = 10 KiB)
    dw 0x7E00       ; Destination buffer offset
    dw 0x0000       ; Destination buffer segment (0x0000:0x7E00 = 0x0007E00)
    dd 1            ; Starting LBA lower 32 bits (LBA 1 = Sector immediately after MBR)
    dd 0            ; Starting LBA upper 32 bits

; ------------------------------------------------------------------------------
; MBR Padding & Boot Signature
; ------------------------------------------------------------------------------
times 510-($-$$) db 0 ; Pad remaining bytes with zeroes up to byte 510
dw 0xAA55             ; Standard MBR boot signature (Bytes 511-512)
