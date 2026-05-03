🎹 CadenzaOS
An operating system built from scratch using the Zig programming language. CadenzaOS focuses on a clean, educational architecture with a custom filesystem and a responsive, predictive kernel-level shell.

🚀 Recent Architectural Milestones
Gateway Architecture: The Shell (UI) is now decoupled from the Kernel (Logic) via a formal System Call Interface.

Standardized Time & Entropy: Implementation of a fixed 100Hz Programmable Interval Timer (PIT) frequency. This provides a universal "tick" ($10ms$) that ensures consistent command velocity monitoring and security lockouts across different hardware and emulators.

🧠 Core Systems
🎼 The Conductor
Tempo Monitoring: Real-time analysis of hardware vitals using standardized PIT ticks and CPU cycle counting (RDTSC).

State Machine: Automatically shifts between Optimal, Discordant, and Critical states based on I/O latency.

Velocity Entropy: Monitors command input speed. High-velocity "mashing" triggers policy-based cooling periods (e.g., a 5-second lockout in ADMIN mode) to prevent command-injection or accidental spamming.

🏛️ Syscall Gateway
Subsystem Abstraction: Centralized syscall.zig serves as the single entry point for user-facing commands to request kernel services.

Habit Recording: Transparently routes shell events to the Markov Engine via the RECORD_HABIT gateway.

Security: Implements compile-time bounds checking on enums to prevent unauthorized memory access across the gateway.

🧠 The Composer (Predictive Shell)
Markov Chain "Brain": A transition-based heuristic engine that learns your command sequences in real-time.

Ghost-Text Prediction: Contextual command suggestions that appear even on empty lines based on session history.

Persistence: Serializes the transition table to /sys/composer.dat for cross-session learning that survives reboots.

📂 CodaFS (Adaptive Filesystem)
Extent-Based Storage: Efficient block management for file growth and directory handling.

Policy-Aware Superblock: Hardware-level enums (Admin, Dev, Gaming) dictate the Conductor's behavioral bias and shell security constraints.

Write-Through Integrity: Workspace mirroring to physical ATA storage for reliable persistence.

🛠️ Command Suite
Filesystem: ls, cd, mkdir, touch, edit, cat, del, mv, rename, stat, df (Disk Free).

System: policy (manual override), vitals (latency telemetry), history, clear, uptime (Standardized clock check), sync (Buffer flush).

Power: shutdown, reboot

🏗 Project Structure
../Cadenza/
├── src
│   ├── boot
│   │   └── boot.asm
│   ├── kernel
│   │   ├── arch_utils.s
│   │   ├── bitmap.zig
│   │   ├── boot_info.zig
│   │   ├── conductor.zig
│   │   ├── config.zig
│   │   ├── convert.zig
│   │   ├── debug.zig
│   │   ├── drivers
│   │   │   ├── ata.zig
│   │   │   └── mouse.zig
│   │   ├── E820Store.zig
│   │   ├── e820_test.zig
│   │   ├── E820.zig
│   │   ├── frame_allocator.zig
│   │   ├── fs
│   │   │   ├── ata_block_device.zig
│   │   │   ├── block_device.zig
│   │   │   ├── coda_file.zig
│   │   │   ├── coda_fs.zig
│   │   │   ├── coda_sm.zig
│   │   │   └── ramdisk.zig
│   │   ├── idt.zig
│   │   ├── inputs
│   │   │   ├── keyboard.zig
│   │   │   └── key_event.zig
│   │   ├── interrupts
│   │   │   └── irq_stubs.asm
│   │   ├── irupts.zig
│   │   ├── kernel.zig
│   │   ├── memory.zig
│   │   ├── page_allocator.zig
│   │   ├── panic.zig
│   │   ├── pic.zig
│   │   ├── port_io.zig
│   │   ├── security.zig
│   │   ├── shell.zig
│   │   ├── syscall.zig
│   │   ├── system.zig
│   │   ├── terminal.zig
│   │   ├── tests.zig
│   │   ├── ui
│   │   │   └── prompt.zig
│   │   ├── vga.zig
│   │   └── vitals.zig
│   └── stage2
│       └── stage2.asm



⏳ Roadmap
✅ Phase 4: Markov Brain & Persistence.

✅ Phase 5: Contextual Prioritization & PIT Standardisation.

🔄 Phase 6 (In-Progress): The Sentinel. Automating the transition from Discordant to Optimal via predictive I/O scheduling and finalizing CodaFS space management.
