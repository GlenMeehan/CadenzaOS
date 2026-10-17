ENTRY(_start)

SECTIONS
{
    . = 0x0;

    .header : {
        _header_start = .;
        KEEP(*(.header))
        _header_end = .;
    }

    .text   : { *(.text) *(.text.*) }
    .rodata : { *(.rodata*) }
    .data   : { *(.data*) }

    /* End of the file-backed image (what objcopy -O binary emits) */
    _image_end = .;

    .bss    : { *(.bss*) }
    _bss_end = .;

    /DISCARD/ : {
        *(.eh_frame)
        *(.eh_frame_hdr)
        *(.comment)
    }

    ASSERT(_header_start == 0, "header must sit at image offset 0")
    ASSERT(_header_end - _header_start == 16, "header must be exactly 16 bytes")
    ASSERT(_bss_end == _image_end, ".bss is not supported yet: the loader only allocates the file-backed size")
}
