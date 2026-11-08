# CadenzaOS 0.7.0

CadenzaOS now boots to the shell on real hardware. This release fixes the bootloader, memory setup and disk driver problems that stopped it on a Dell OptiPlex 3020.

## What's new
- **Boots on real hardware.** Tested on one machine, a Dell OptiPlex 3020 (legacy BIOS boot, 8 GB RAM, SATA controller in ATA/IDE mode). It reaches the shell, and the filesystem mounts and reports healthy.
- **ATA driver finds the controller through PCI.** The driver used to assume the legacy ports `0x1F0`/`0x3F6`. If the IDE controller is in PCI native mode, it now reads the command and control ports from BAR0/BAR1 (new `pci.zig`, plus `inl`/`outl` in `port_io.zig`). Otherwise it keeps the legacy ports, so QEMU behaves as before. It prints the ports it chose to serial as `ATA cmd=... ctl=...`.

## Fixes
- **Kernel image not visible after the BIOS disk reads.** Stage 2 now reloads `FS` after `int 13h` before copying the kernel above 1 MiB.
- **Kernel BSS was only about 1.5% cleared.** The old 16-bit loop used `loop`, which counts only CX. The whole BSS is now cleared in long mode. QEMU hid this because its RAM starts zeroed.
- **Page tables:** the kernel high half (`0xFFFFFF8000000000`) is now mapped through PML4[511], its correct index.
- **A20:** stage 2 never writes the fast-reset bit (bit 0) of port `0x92`.
- **Frame allocator panic on machines with more than 1 GiB of RAM.** `bitmap.init` panicked with "Bitmap storage too small". It now manages the first 1 GiB and leaves the rest unmanaged.
- **Disk waits fail fast.** `wait_bsy` returns an error at once when the status register reads `0xFF` (no device).
- The `CP3: bitmap init done` serial marker now prints after the init instead of before it.
- The `B` marker from the old BSS clear is removed from stage 2's output.

## Other changes
- A security policy (`SECURITY.md`), a read-only token for the smoke workflow, a README logo, and an optional `QEMU_CPU` setting for `build.sh`.

## Upgrading
- No format changes. Rebuild with `./build.sh` as usual.
- To run on real hardware, set the SATA controller to ATA/IDE mode in the BIOS. AHCI mode is not supported. See `docs/REAL_HARDWARE.md`.

## Known issues
- **Keyboard input is doubled on the Dell.** Cause not yet investigated.
- Only one real machine has been tested, and only legacy BIOS boot and IDE mode are supported.
- Memory above 1 GiB is not managed, and stage 2 maps only the first 64 MiB.
- `writeBlocks` has its own busy loop with no timeout or `0xFF` check.
- Programs run in ring 0 with no memory protection.
- The bundle holds at most 12 programs, and the root directory about 20 entries. Creating a file in a full root directory leaks two disk blocks.
- Special keys (arrows, Tab, Escape, Home, End, Delete) still reach the shell while a foreground program runs, and any program can read the shared keyboard queue.
- Creating or moving a file does not check for an existing name in the target directory.

**Full changelog:** https://github.com/GlenMeehan/CadenzaOS/compare/v0.6.0...v0.7.0
