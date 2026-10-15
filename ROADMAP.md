Cadenza OS Roadmap

This tracks planned work beyond the current stable baseline. It's a living document — update it as priorities shift or items get done. The README has a shorter phase overview; this file is the detailed plan. Small, well-described tasks are filed as GitHub issues with difficulty labels (level: beginner, level: intermediate, level: advanced).

Current state (as of v0.4.7):

Builds from a clean checkout and boots to the shell in QEMU. CI builds every push and checks that the shell prompt appears.
Disk persistence via CodaFS, preemptive multitasking, and a splash screen with progress reporting.
Programs are built from source in userland/, installed into CodaFS, and started with spawn <program> [args...]. They have a validated 16-byte header and receive argc/argv.
On real hardware (Dell OptiPlex 3020, legacy BIOS) it boots but does not yet reach the shell. Waiting on serial-output hardware to debug it.
Everything still runs in ring 0 with no memory protection.
1. Close out loose ends
 Resolve real-hardware garbling and reach the shell on the OptiPlex (literal-string test pending — determine whether it's the rendering path or the data reaching it). Blocked on serial hardware.
 Retest the recent scheduler, interrupt-stack and cursor fixes on real hardware
 Confirm whether the OptiPlex needs AHCI support or legacy IDE compat mode is sufficient long-term
 Verify the persistence fix and MBR boot fix together on real hardware
 Add wait_bsy/wait_drq-style timeout guards anywhere else in the driver layer that still busy-waits unconditionally, and tune the existing timeout (the current 10,000,000-iteration value is an untuned guess)
 Finish .gitignore cleanup (decide whether bochsrc*.txt stay tracked; check which screenshots the README uses)
 Reduce the kernel image size (about 3,500 sectors; the embedded Splash.rgb is 768 KiB and about 200 KiB of undefined buffers are stored in .data). See the issues labelled cleanup
 Decide RAMDISK_SIZE: the filesystem is currently 4 MiB of an 8 MiB partition
 Remaining cleanup (debug logging, dead yield(), framebuffer.zig palette comment, flushToDisk bounds check, dead legacy formatting code in ata.zig) — tracked as issues
 Fix the shell stack overflow that corrupted the kernel allocator (shell stack enlarged to 64 KiB in .bss)
 Fix getCycles() (read both halves of the timestamp counter)
 Move prog1 staging out of the kernel image's way (APP_LBA_START now in config.zig, with build-time and compile-time overlap checks)
2. Bin loader / user programs
 Define a minimal on-disk program format/ABI: 16-byte header (magic, version, entry offset, image size), argc in rdi, argv in rsi, stack layout documented in docs/LAYOUT.md
 Support loading a program from the real filesystem (spawn uses findFile/readFile)
 Take the program's real size from its header instead of a hard-coded constant
 Build prog1 from source in userland/prog1/ as part of ./build.sh
 Install more than one program: installEmbeddedApps currently only knows prog1
 Support .bss in programs (needs a memory-size field in the header; the linker script currently rejects a non-empty .bss)
 Document and verify the memory layout a program can assume (position-independence in particular)
3. Process isolation
 Per-process page tables — each process gets its own address space
 Ring 3 user mode — stop running everything at ring 0
 Minimal syscall gate (int 0x80 or syscall/sysret) with a small, deliberate surface. Currently implemented (ring 0): exit, print string, print char, scratch byte get/set/increment. Still to add: read (keyboard input), yield, and validation of every pointer a program passes in
 Fault isolation — a crashing user process should not take down the kernel
 Detect stack overflow with guard pages or canaries, instead of silent corruption
4. Predictive shell + filesystem telemetry
 Bounded ring buffer of recent shell commands
 Simple Markov chain over command sequences ("what usually follows X")
 Suggestion surface in the shell (never auto-execute; destructive commands excluded from auto-suggestion entirely)
 Wire shell-level predictions into CodaFS as prefetch hints — hints inform prefetch timing only, never bypass normal permission/validation checks on the actual read
 Keep the model dumpable/inspectable as plain data (no opaque state)
<!-- TODO: the README says the ghost-text prediction and Markov chain already work in the shell. Check which of these items are already done and tick them. -->
5. Security, in step with the above
 Prefetched data always re-validated through the same checks as a normal read — no shortcuts from prediction confidence
 Once process isolation lands: user processes get no direct access to kernel-internal history/telemetry structures, only indirect influence through normal, checked I/O
 If/when multi-user support exists: keep learned patterns/history scoped per-user, not shared across processes
6. Project and community
 CI smoke test: build from a clean checkout and boot to the shell prompt
 DEPENDENCIES.md, docs/LAYOUT.md, README status section, labels, GitHub Discussions, issue-template configuration
 Smoke test stage two: send commands through the QEMU monitor (for example spawn prog1 hello, then create and delete a file) and check the serial log
 Preflight check in build.sh that lists any missing tools in one message
 Settle the open items marked TODO in docs/LAYOUT.md
7. Longer-term / open questions
Multithreading — deliberately deferred; revisit only once process isolation exists and a real need (e.g. in-process concurrency) shows up
AHCI driver support, if confirmed necessary for broader real-hardware compatibility
UEFI boot path — separate bootloader, not a flag on the existing one; out of scope until the legacy BIOS path is fully solid
