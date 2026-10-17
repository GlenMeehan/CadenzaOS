# Disk layout and memory map

This describes where things live on the disk image and in memory. Disk numbers come from
`src/kernel/config.zig` and `build.sh`, which are the single sources of truth. If this
document and those files ever disagree, the code wins, so please fix the document.

Kernel addresses change with every build. Get the current ones with
`nm -S build/kernel.elf` and `readelf -lW build/kernel.elf`.

<!-- TODO: items marked TODO below are not yet verified against the code. -->

## Disk image

`./build.sh` creates a 10 MiB image: 20,480 sectors of 512 bytes (`DISK_SECTOR_COUNT`).
Sector numbers here are **absolute** (from the start of the image).

| Sectors | Size | Contents | Defined in |
|---|---|---|---|
| 0 | 1 sector | Stage 1 boot sector (`boot.bin`) | `build.sh` |
| 1 to 15 | 3 sectors used today | Stage 2 (`stage2.bin`, 1,528 bytes, written at sector 1) | `build.sh`; limited by `KERNEL_LBA` |
| 16 onwards | kernel size (about 3,500 sectors today) | Kernel image (`kernel.bin`) | `KERNEL_LBA` in `build.sh` |
| 3700 to 3747 | 48 sectors | Raw app staging area (`prog1.bin`) | `APP_LBA_START`, `APP_MAX_SECTORS` in `config.zig` |
| 4096 to 20479 | 16,384 sectors (8 MiB) | CodaFS partition | `PARTITION_START_LBA` in `config.zig` |

Everything between the end of the kernel and sector 3700, and between 3748 and 4095, is unused.

Rules that keep the regions apart:

### The app staging area

`build.sh` builds every program under `userland/` and packs them into one bundle
(`tools/pack.sh`, format in `src/kernel/bundlefmt.zig`), written raw at `APP_LBA_START`.
Sector 0 holds a header and a table of up to 12 programs; each program follows on its own
sector boundary. On boot, `installEmbeddedApps` copies every program that is not already in
CodaFS into the root directory under its bundle name. Existing files are not overwritten, so
answer **n** to the "Preserve filesystem?" prompt to refresh a program you changed.
- `config.zig` fails to compile if `APP_LBA_START + APP_MAX_SECTORS` passes `PARTITION_START_LBA`.
- Nothing checks that stage 2 fits in sectors 1 to 15. It uses 3 today, so there is plenty of room, but a guard like the kernel one would be cheap.

### The app staging area

`build.sh` builds `prog1` from `userland/prog1/` and writes `prog1.bin` raw at `APP_LBA_START`.
On the first boot of a fresh image, `installEmbeddedApps` reads it from there and copies it into
CodaFS as the file `prog1`. It does this **only if `prog1` does not already exist**, so on a
preserved image CodaFS keeps its old copy. Answer **n** to the "Preserve filesystem?" prompt to
reinstall.

### Inside the CodaFS partition

Block numbers here are **relative to the start of the partition**. The absolute sector is
`PARTITION_START_LBA + block`. These values come from `CodaFs.mkfs` and `config.zig`.

| Block | Contents |
|---|---|
| 0 | Superblock (`SB_LBA = 0`) |
| 1 to 16 | Space-manager region (`sm_start_block = SB_LBA + 1`, `sm_block_count = 16`). Block 1 holds the header; the packed free-extent list starts at block 2 |
| 17 to 20 | Root directory (4 blocks, the first allocation after `mkfs`) |
| 21 onwards | File data and metadata, handed out first-fit by the space manager |

The filesystem runs through a RAM disk (see below) with write-through to the ATA disk.
The RAM disk's block count is its buffer size divided by the block size (`ramdisk.zig`), so
with `RAMDISK_SIZE` at 4 MiB the filesystem has **8,192 blocks (4 MiB)**. Block `N` is written
to absolute sector `PARTITION_START_LBA + N`. The upper half of the partition (sectors 12288
to 20479) is therefore not used by the filesystem today. Using all of it would need a larger
`RAMDISK_SIZE` (8 MiB) and a mapping that covers it.

## Memory

All kernel code and data are mapped in the higher half. The kernel image is loaded at
physical `0x100000` and mapped at `0xFFFFFF8000100000`, so for these regions
virtual = physical + `KERNEL_OFFSET` (`memory.physToVirt`; the offset is `0xFFFFFF8000000000`).

| Physical | Virtual | Size | Contents |
|---|---|---|---|
| `0x500` | | 56 bytes | GDT (seen in QEMU: base `0x500`, limit `0x37`) |
| `0x1000` | | 64 KiB (`PAGE_TABLE_BYTES`) | Early page tables (CR3 is `0x1000` in QEMU) <!-- TODO: confirm the exact range --> |
| `0x20000` to `0x29000` | | 36 KiB | TSS at `0x20000`, then the IST1 interrupt stack (32 KiB, top at `0x29000`). Reserved from the frame allocator with `markUsedRange` |
| `0x100000` | `0xFFFFFF8000100000` | kernel image | `.text`, `.rodata`, `.data`: first `LOAD` segment, mapped read-write-execute |
| after the kernel image | | see below | `.bss`: the second `LOAD` segment |
| `0x2000000` | `0xFFFFFF8002000000` | 4 MiB | RAM disk (`RAMDISK_VIRT_ADDR`, `RAMDISK_SIZE`) |

### What is in `.bss`

Zero-initialised and not stored in the kernel image. The main items in `kernel.zig`:

| Symbol | Size | Purpose |
|---|---|---|
| `heap_buffer` | 10 MiB | Backing store for the kernel allocator (`fba`, a `FixedBufferAllocator`) |
| `kmain_stack` | 16 KiB | Permanent boot stack |
| `shell_stack_buf` | 64 KiB | Stack the shell runs on after the stack switch |
| `fs_global` | | The mounted filesystem |

The kernel allocator is a fixed-buffer allocator: it can only hand out and free from
`heap_buffer`, and freeing a pointer from anywhere else trips an assertion.

### Physical frames

Physical pages (4 KiB) are handed out by a bitmap allocator (`frame_allocator.zig`, `bitmap.bitmap_storage`).
Task stacks and program images come from here.

Reserved from the allocator at startup (`kernel.zig`, using `markUsedRange`):

- the kernel image
- the stack that stage 2 hands over (`STACK_SIZE`, `0x40000` bytes = 256 KiB, ending at `info.stack_top`)
- the heap (`heap_buffer`, 10 MiB)
- the E820 memory-map table
- the RAM disk
- the shell stack
- `0x7000` to `0x8000` (4 KiB)
- `0x20000` to `0x29000` (the TSS and IST1 stack)

<!-- TODO: say what lives at 0x7000, what the two range-based reservations near kernel.zig:620 cover, whether the GDT (0x500) and early page tables (0x1000) are reserved, and how much RAM the 32 KiB bitmap covers -->

## Stacks

| Stack | Size | Where it lives |
|---|---|---|
| Stage 2 stack (`STACK_SIZE`) | 256 KiB | Reserved from the frame allocator, ends at `info.stack_top` |
| Boot stack (`kmain_stack`) | 16 KiB | `.bss` |
| Shell (`shell_stack_buf`) | 64 KiB | kernel image, zero-initialised |
| Task stack | 32 KiB (`TASK_STACK_PAGES = 8`) | Frame allocator, one per spawned program |
| IST1 interrupt stack | 32 KiB | Physical `0x20000` region |

**Layout of a task stack** (high addresses at the top):

```
 top of stack_mem
 +--------------------------------+
 | InterruptContext save area     |   reserved: preempt_handler copies the interrupted
 |                                |   context here on every context switch
 +--------------------------------+
 | argument strings               |
 | argv[0..argc], NULL            |
 | synthetic return-address slot  |   <- initial RSP (8 mod 16, per the SysV ABI)
 +--------------------------------+
 | task stack grows down from here|
```

The save area at the top must stay reserved and must match the destination `preempt_handler`
uses. Putting anything else there corrupts a running task on its first preemption.

The shell stack was once 16 KiB, which sat directly above the kernel allocator object in memory
and overflowed into it. The size and the zero-initialised placement are deliberate.

## Interrupts

| Vector | Source | Stack |
|---|---|---|
| 32 | IRQ0, timer (also drives preemption) | IST1 |
| 33 | IRQ1, keyboard | IST1 |
| 44 | IRQ12, mouse | IST1 |
| `0x80` | Syscall (`int $0x80`) | normal (interrupt gate) |
| 0 to 31 | CPU exceptions | normal |

The three IRQs share one IST1 stack, so the timer handler copies the interrupted context
out of it into the outgoing task's own stack before returning.
<!-- TODO: confirm the vector numbers against idt.zig and irq_stubs.asm -->
