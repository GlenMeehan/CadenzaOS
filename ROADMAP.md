Cadenza OS Roadmap

This tracks planned work beyond the current stable baseline. It's a living document — update it as priorities shift or items get done.

Current state (as of v0.2.0): boots on real hardware (Dell OptiPlex 3020, legacy BIOS), disk persistence via CodaFS working, preemptive multitasking in place, splash screen with progress reporting.

1. Close out loose ends
 Resolve real-hardware panic/text garbling (literal-string test pending — determine whether it's the rendering path or the data reaching it)
 Confirm whether OptiPlex needs AHCI support or legacy IDE compat mode is sufficient long-term
 Finish .gitignore cleanup (build artifacts, emulator logs, stale disassembly files) — in progress
 Verify persistence fix and MBR boot fix together on real hardware
 Add wait_bsy/wait_drq-style timeout guards anywhere else in the driver layer that still busy-waits unconditionally
2. Bin loader / user programs
 Finish the embedded-app loading path (bin_loader.installEmbeddedApps) beyond the current read-back verification test
 Define a minimal on-disk program format/ABI (entry point, how args are passed, expected memory layout)
 Support loading a program from the real filesystem, not just an embedded/staged binary
3. Process isolation
 Per-process page tables — each process gets its own address space
 Ring 3 user mode — stop running everything at ring 0
 Minimal syscall gate (int 0x80 or syscall/sysret) with a small, deliberate surface to start: exit, read, write, yield
 Fault isolation — a crashing user process should not take down the kernel
4. Predictive shell + filesystem telemetry
 Bounded ring buffer of recent shell commands
 Simple Markov chain over command sequences ("what usually follows X")
 Suggestion surface in the shell (never auto-execute; destructive commands excluded from auto-suggestion entirely)
 Wire shell-level predictions into CodaFS as prefetch hints — hints inform prefetch timing only, never bypass normal permission/validation checks on the actual read
 Keep the model dumpable/inspectable as plain data (no opaque state)
5. Security, in step with the above
 Prefetched data always re-validated through the same checks as a normal read — no shortcuts from prediction confidence
 Once process isolation lands: user processes get no direct access to kernel-internal history/telemetry structures, only indirect influence through normal, checked I/O
 If/when multi-user support exists: keep learned patterns/history scoped per-user, not shared across processes
6. Longer-term / open questions
 Multithreading — deliberately deferred; revisit only once process isolation exists and a real need (e.g. in-process concurrency) shows up
 AHCI driver support, if confirmed necessary for broader real-hardware compatibility
 UEFI boot path — separate bootloader, not a flag on the existing one; out of scope until the legacy BIOS path is fully solid
