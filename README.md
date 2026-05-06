🎹 CadenzaOS
An operating system built from scratch using the Zig programming language. CadenzaOS focuses on a clean, educational architecture with a custom filesystem and a responsive, predictive kernel-level shell.

🚀 Recent Architectural Milestones
Validated Extent Management: CodaFS now features a fully functional Space Manager that tracks disk health via extent-list summation rather than simple bitmasking.

Human-Centric Telemetry: The Kernel now converts raw PIT ticks into a real-time decimal uptime display (MM:SS) and provides high-fidelity disk usage reports via the new df implementation.

Buffer-Safe String Synthesis: Implementation of sequential memory-copying patterns for shell output, ensuring atomic VGA writes and preventing buffer overflows during complex string building.

🧠 Core Systems
🎼 The Conductor
Standardized Time: Implementation of a fixed 100Hz Programmable Interval Timer (PIT) frequency. This provides a universal "tick" (10ms) that ensures consistent command velocity monitoring and uptime tracking.

State Machine: Automatically shifts between Optimal, Discordant, and Critical states based on I/O latency.

Velocity Entropy: Monitors command input speed. High-velocity "mashing" triggers policy-based cooling periods to prevent accidental spamming.

📂 CodaFS (Adaptive Filesystem)
Extent-Based Storage: Efficient block management using an ArrayListUnmanaged of extents to track free and allocated space.

Space Accounting: The df command performs a real-time census of the free-list to report Total, Used, and Free blocks.

Write-Through Integrity: Workspace mirroring to physical ATA storage for reliable persistence.

🏛️ Syscall Gateway
Subsystem Abstraction: Centralized syscall.zig serves as the single entry point for user-facing commands to request kernel services.

Security: Implements compile-time bounds checking on enums to prevent unauthorized memory access across the gateway.

🧠 The Composer (Predictive Shell)
Markov Chain "Brain": A transition-based heuristic engine that learns your command sequences in real-time.

Ghost-Text Prediction: Contextual command suggestions that appear even on empty lines based on session history.

📂 CodaFS (Adaptive Filesystem)
Extent-Based Storage: Efficient block management for file growth and directory handling.

Policy-Aware Superblock: Hardware-level enums (Admin, Dev, Gaming) dictate the Conductor's behavioral bias and shell security constraints.

Write-Through Integrity: Workspace mirroring to physical ATA storage for reliable persistence.

🛠️ Command Suite
Filesystem: ls, cd, mkdir, touch, edit, cat, rm, mv, rename, stat, df (Disk Free).

System: policy, vitals, history, clear, uptime (Human-readable clock), sync.

Power: shutdown, reboot.

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

✅ Phase 5: CodaFS Extent Tracking & PIT Standardization.

🔄 Phase 6 (In-Progress): Multitasking. Implementing the Task Scheduler, Context Switching logic, and the transition to a multi-process environment.
