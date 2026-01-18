ENTRY(kernel_entry)

KERNEL_OFFSET = 0xFFFFFF8000000000;

SECTIONS {
    /* Load kernel at 1MiB */
    . = KERNEL_OFFSET + 0x00100000;

    /* Mark start of the kernel image */
    _kernel_start = .;

    /* Put all executable code first */
    .text : ALIGN(16) {
        KEEP(*(.text.kernel_entry))   /* make sure kernel_entry is first */
        *(.text*)                     /* rest of code */
    }

    /* Read-only data next */
    .rodata : ALIGN(16) {
        *(.rodata*)
    }

    /* Initialized data */
    .data : ALIGN(16) {
        *(.data*)
    }

    /* Uninitialized data (includes your IDT) */
    .bss : ALIGN(16) {
        *(.bss*)
        *(COMMON)
    }

    /* Mark end of kernel image */
    _kernel_end = .;
}
