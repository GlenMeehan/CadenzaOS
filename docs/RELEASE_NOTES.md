# CadenzaOS 0.6.0

Programs can now read the keyboard, and a number of filesystem and input bugs are fixed.

> The `v0.5.0` tag points at an older commit (its code reports version 0.4.7) and does not
> contain the changes released as "0.5.0". This release includes them. Please use 0.6.0.

## What's new
- **Keyboard input for programs.** Two new syscalls: `read` (6), a non-blocking read from the
  keyboard queue, and `yield` (7), which gives up the rest of the time slice. A program that
  wants to wait for input loops on `read` and `yield`. The test program `kbecho` uses both.
- **Safer `print`.** Syscall 1 now checks that the whole buffer lies inside the calling task's
  own memory. A bad buffer prints nothing.
- **Foreground programs.** `spawn <program>` now waits until the program exits, and the shell
  does not read the keyboard in the meantime, so the program receives every keystroke.
- **Multiple programs.** `./build.sh` builds every program under `userland/<name>/`
  (it needs `<name>.zig` and `linker.ld`), packs them into one bundle, and the kernel installs
  each into CodaFS on boot under its own name. Programs: `prog1`, `hello`, `kbecho`.
  Details are in `docs/LAYOUT.md`.
- **A much stronger smoke test.** CI now types into the running OS and checks: program
  arguments, `touch`/`del`/`mkdir`/`mv`, typing into `kbecho`, and that each installed program
  is listed exactly once.
- **Build:** `src/kernel/version.zig` is generated on every build and is no longer tracked.
- **Documentation:** `docs/LAYOUT.md`, `DEPENDENCIES.md`, a clearer README with a status
  section, and an updated roadmap.

## Fixes
- **Each installed program was listed twice** in the root directory, using two of its
  roughly 20 slots, and `del` on it left an entry pointing at freed blocks.
- **`del` and `mv` could not find a file stored beyond the first directory block.** Both now
  scan every block, and `del` frees blocks only after the entry is removed.
- **A stray `y` (or `n`) stayed in the input after answering a confirmation prompt** and
  appeared at the next prompt.
- **Program output could be split in the middle of a line** by the scheduler's trace
  messages, which made CI fail intermittently. The trace is now off by default
  (`config.debug_sched_trace`).
- A failed program install no longer leaks filesystem space.
- The boot-time test read of `/prog1` is gone, so the shell starts whichever programs are installed.
- VGA palette values now match their colour names, and `clearScreen` respects the
  framebuffer's channel layout (#14).
- Removed the unused `Scheduler.yield()` and its call sites (#15).

## Upgrading
- **Wipe any existing disk image** and let `./build.sh` create a fresh one. Older images hold
  duplicate directory entries, and images on which `del` failed with "File not found" may
  contain blocks that were handed out twice.
- Answer **n** to "Preserve filesystem?" after changing a program: an existing file is never
  overwritten. New programs are added even on a preserved filesystem.
- The raw app staging area is 256 sectors (`APP_MAX_SECTORS` in `config.zig`).

## Known issues
- On real hardware (Dell OptiPlex 3020) it boots but does not yet reach the shell, and text is
  garbled. QEMU is the supported way to run it. Serial-output hardware is on order.
- Programs run in ring 0 with no memory protection.
- The bundle holds at most 12 programs, and the root directory about 20 entries. Creating a
  file in a full root directory leaks two disk blocks.
- Special keys (arrows, Tab, Escape, Home, End, Delete) still reach the shell while a foreground
  program runs, and any program can read the shared keyboard queue.
- Creating or moving a file does not check for an existing name in the target directory.

## Thanks
Thanks to @Haxxyyyy for the palette and `yield()` pull requests, their first contributions.

**Full changelog:** https://github.com/GlenMeehan/CadenzaOS/compare/v0.4.7...v0.6.0
