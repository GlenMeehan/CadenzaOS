ENTRY(kernel_entry)

/* Virtual Address (Higher Half) */
KERNEL_OFFSET = 0xFFFFFF8000000000;
/* Physical Address (1MiB) */
KERNEL_PHYS   = 0x00100000;

/* Define the Disk Anchor (Physical: 16MB) */
DISK_PHYS = 0x01000000;
DISK_VIRT = KERNEL_OFFSET + DISK_PHYS;

SECTIONS {
    /* Set the location counter to the Virtual Address */
    . = KERNEL_OFFSET + KERNEL_PHYS;

    _kernel_start = .;

    /* .text section starts at Virtual Address, but is Loaded at Physical Address */
    .text : AT(ADDR(.text) - KERNEL_OFFSET) ALIGN(16) {
        KEEP(*(.text.kernel_entry))
        *(.text*)
    }

    .rodata : AT(ADDR(.rodata) - KERNEL_OFFSET) ALIGN(16) {
        *(.rodata*)
    }

    .data : AT(ADDR(.data) - KERNEL_OFFSET) ALIGN(16) {
        *(.data*)
    }

    /* BSS is slightly different: it has no data in the file (AT isn't strictly needed,
       but we keep alignment consistent) */
    .bss : AT(ADDR(.bss) - KERNEL_OFFSET) ALIGN(16) {
        *(.bss*)
        *(COMMON)
    }

    _kernel_end = .;

/* Check to ensure the kernel hasn't grown into the disk space */
    ASSERT(. < DISK_VIRT, "Error: Kernel has grown too large and is overlapping the RAM disk area!")

}
