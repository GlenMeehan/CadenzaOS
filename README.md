🎹 CadenzaOS
An operating system built from scratch using the Zig programming language. CadenzaOS focuses on a clean, educational architecture with a custom filesystem and a responsive kernel-level shell.

🚀 Current Features
-Monolithic-Kernel Foundation: Written in Zig (Targeting 0.16.0), leveraging its type safety and manual memory management.
-CodaFS (Adaptive Hierarchy): A custom-designed, extent-based filesystem.
-Context-Aware Navigation: Supports a tree-based directory structure with a Current Working Directory (CWD).
-Policy-Aware Superblock: Hardware-level enums (Admin, Dev, Gaming, AI_Guided) that dictate system behavior.
-Write-Through Cache: Uses a 4MB RAM workspace mirrored to physical ATA storage for persistence.
-Intelligent Predictive Shell:
-Contextual Heuristics: The shell now prioritizes commands based on the System Policy (e.g., boosting vitals priority when in Admin mode).
-Markov Chain "Brain": A transition-based heuristic engine that learns command sequences in real-time.
-Ghost-Text Prediction: Responsive VGA rendering with "Switch-over" logic to support long-string inputs without display duplication.
-Persistence: Serializes the transition table to /sys/brain.dat for cross-session learning.

🖥️Terminal & I/O:
-Hybrid Rendering: A dual-mode terminal that uses Canvas-style redrawing for short commands (ghost text) and TTY-style streaming for long data entries.
-I/O Telemetry: Real-time monitoring of disk latency using CPU cycle counting (RDTSC).
-VGA Driver: Direct hardware rendering with 80x25 text mode and hardware cursor synchronization.

📂 Filesystem & System Commands
ls / cd / mkdir: Standard filesystem navigation.
edit: One-shot file editor with auto-growth and block-aware append logic.
cat / rm / stat: File reading, deletion, and metadata/latency inspection.
policy: View or manually override the system operation mode (Admin, Dev, Gaming, AI).
version: Displays kernel and predictive shell build information.
history: View the command history buffer.

🏗 Project Structure
/src/kernel: Core kernel logic and shell implementation.
/src/kernel/fs: CodaFS implementation, Telemetry hooks, and Space Manager.
/src/kernel/drivers: Hardware abstraction (VGA, Keyboard, ATA/IDE).

🛠 Build & Environment
Prerequisites: Zig 0.16.0, NASM, and QEMU (x86_64).
Instructions: Run chmod +x build.sh and then ./build.sh to compile the kernel, assemble the bootloader, and launch the image in QEMU.

⏳ Roadmap
✅ Phase 4 (Complete): Markov Brain & Persistence.
✅ Phase 5 (Complete): Contextual Prioritization & Hybrid Terminal Rendering.
⏳ Phase 6: The Sentinel: Implementation of telemetry-driven self-healing logic (IO-to-Policy automation).
