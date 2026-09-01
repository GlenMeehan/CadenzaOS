ENTRY(kernel_entry)

/* Virtual Address (Higher Half) */
KERNEL_OFFSET = 0xFFFFFF8000000000;
/* Physical Address (1MiB) */
KERNEL_PHYS   = 0x00100000;

/* Define the Disk Anchor (Physical: 16MB) */
DISK_PHYS = 0x01000000;
DISK_VIRT = KERNEL_OFFSET + DISK_PHYS;

PHDRS
{
    /* Single LOAD segment for file contents (Code & Data) */
    text PT_LOAD FLAGS(7); /* Read + Write + Execute */
    /* Separate LOAD segment for uninitialized memory (BSS) */
    bss  PT_LOAD FLAGS(6); /* Read + Write */
}

SECTIONS {
    . = KERNEL_OFFSET + KERNEL_PHYS;

    _kernel_start = .;

    /* File-backed sections assigned explicitly to :text header */
    .text : AT(ADDR(.text) - KERNEL_OFFSET) ALIGN(16) {
        KEEP(*(.text.kernel_entry))
        *(.text*)
    } :text

    .rodata : AT(ADDR(.rodata) - KERNEL_OFFSET) ALIGN(16) {
        *(.rodata*)
    } :text

    .data : AT(ADDR(.data) - KERNEL_OFFSET) ALIGN(16) {
        *(.data*)
    } :text

    /* BSS section mapped to :bss header so it doesn't inflate file offsets */
    .bss : AT(ADDR(.bss) - KERNEL_OFFSET) ALIGN(16) {
        *(.bss*)
        *(COMMON)
    } :bss

    _kernel_end = .;

    /* Check to ensure the kernel hasn't grown into the disk space */
    ASSERT(. < DISK_VIRT, "Error: Kernel has grown too large and is overlapping the RAM disk area!")
}
