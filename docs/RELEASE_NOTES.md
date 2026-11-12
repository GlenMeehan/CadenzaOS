# CadenzaOS 0.7.1

A small follow-up to 0.7.0 that fixes the two remaining problems seen on the Dell OptiPlex 3020: doubled keyboard input and a slow uptime clock.

## Fixes
- **Doubled keyboard input on real hardware.** On the Dell (USB keyboard) IRQ1 fired twice per key, and the second interrupt found the 8042 output buffer empty, so port `0x60` returned the previous byte again. `irq1_handler` now reads the scancode only when the controller's status bit 0 reports data waiting, and still sends the EOI. This also stopped the stuck-capitals symptom seen on that machine.
- **Timer ran at the wrong rate on real hardware.** The LAPIC timer used a fixed initial count tuned on QEMU, while the tick handler assumes 100 Hz, so uptime and scheduling ran several times too slow on the Dell. The timer is now calibrated at boot against PIT channel 2, with a fallback to the old constant if the measurement fails. The measured count is printed to serial as `LAPIC calib: count=...`.

## Documentation
- `docs/REAL_HARDWARE.md` and the README now describe the tested hardware accurately, and note that a CMOS reset or "load defaults" reverts the BIOS settings (SATA back to AHCI, serial port off), which shows up as a splash screen followed by an immediate `IoError`.
- The README now gives the correct framebuffer mode (1024x768x32), lists all three demo programs and has a shorter, accurate project tree.

## Known issues
- **`shutdown` hangs on real hardware.** It writes to a QEMU-only port; real hardware needs ACPI.
- Only one real machine has been tested, and only legacy BIOS boot and IDE mode are supported. There is no AHCI or UEFI support.
- Memory above 1 GiB is not managed, and stage 2 maps only the first 64 MiB.
- `writeBlocks` has its own busy loop with no timeout or `0xFF` check.
- Programs run in ring 0 with no memory protection.
- The bundle holds at most 12 programs, and the root directory about 20 entries. Creating a file in a full root directory leaks two disk blocks.
- Special keys (arrows, Tab, Escape, Home, End, Delete) still reach the shell while a foreground program runs, and any program can read the shared keyboard queue.
- Creating or moving a file does not check for an existing name in the target directory.

**Full changelog:** https://github.com/GlenMeehan/CadenzaOS/compare/v0.7.0...v0.7.1
