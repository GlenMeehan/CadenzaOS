# CadenzaOS 0.8.0

CadenzaOS now builds with Zig 0.17.1. Zig 0.16.0 is no longer supported.

## Changes
- **Toolchain upgrade to Zig 0.17.1.** The kernel and the demo programs build with 0.17.1 and boot to the shell in QEMU (CI-tested) and on the Dell OptiPlex 3020.
- **Array repetition:** the removed `**` operator is replaced by `@splat` throughout (bitmap storage, IDT, keymaps, filesystem structures, scheduler task table and others).
- **Space manager:** `ArrayListUnmanaged(Extent)` initialisers in `coda_sm.zig` now set the new `pointer_stability` field.
- **Scheduler:** the `InterruptContext` field reflection in `registerDynamicTask` uses `@typeInfo(...)` in place of the removed `std.meta.fields`.
- **Formatting:** `zig fmt` from 0.17.1 reformatted several files, so some diffs are whitespace only.
- The shell's `version` output reports Zig 0.17.1.
- **Enum conversion:** `@intFromEnum` is replaced by `@backingInt` in the shell's habit and tempo code.

## Upgrading
- Install Zig 0.17.1 and point `ZIG` at it (see `DEPENDENCIES.md`). Zig 0.16.0 will not build this release.
- Rebuild with `./build.sh`. No disk format changes.

## Known issues
- **`shutdown` hangs on real hardware.** It writes to a QEMU-only port; real hardware needs ACPI.
- Only one real machine has been tested, and only legacy BIOS boot and IDE mode are supported. There is no AHCI or UEFI support.
- Memory above 1 GiB is not managed, and stage 2 maps only the first 64 MiB.
- `writeBlocks` has its own busy loop with no timeout or `0xFF` check.
- Programs run in ring 0 with no memory protection.
- The bundle holds at most 12 programs, and the root directory about 20 entries. Creating a file in a full root directory leaks two disk blocks.
- Special keys (arrows, Tab, Escape, Home, End, Delete) still reach the shell while a foreground program runs, and any program can read the shared keyboard queue.
- Creating or moving a file does not check for an existing name in the target directory.

**Full changelog:** https://github.com/GlenMeehan/CadenzaOS/compare/v0.7.1...v0.8.0
