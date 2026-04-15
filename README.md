# CadenzaOS

An operating system built from scratch using the Zig programming language. CadenzaOS focuses on a clean, educational architecture with a custom filesystem and a responsive kernel-level shell.

🚀 Current Features

* **Monolithic-Kernel Foundation:** Written in Zig, leveraging its type safety and manual memory management.
* **CodaFS (Adaptive Hierarchy):** A custom-designed, extent-based filesystem.
    * **Context-Aware Navigation:** Supports a tree-based directory structure with a Current Working Directory (CWD).
    * **Policy-Aware Superblock:** Hardware-level enums (Admin, Dev, Gaming) that dictate system behavior.
    * **I/O Telemetry:** Real-time monitoring of disk latency using CPU cycle counting (RDTSC).
    * **Write-Through Cache:** Uses a 4MB RAM workspace mirrored to physical ATA storage for instant performance.
* **Intelligent Predictive Shell:**
    * **Markov Chain "Brain":** A transition-based heuristic engine that learns command sequences in real-time.
    * **Ghost-Text Prediction:** Responsive VGA rendering of predicted commands before the user types.
    * **Persistence:** Serializes the 10x10 Markov transition table to `/sys/brain.dat` for cross-session learning.
    * **Smart Completion:** Tab-to-accept and Right-Arrow completion for predicted paths.
    * **Command History:** Circular buffer (32 entries) for navigating past inputs.
* **VGA Driver:** Direct hardware rendering with support for 80x25 and 80x50 text modes.

📂 Filesystem & System Commands

* `ls`: List all files and folders in the current directory.
* `cd <dir>`: Navigate the filesystem tree.
* `mkdir <name>`: Create a new subfolder.
* `mf` / `wf` / `cat`: File creation, writing, and reading.
* `rm <name>`: Deletes a file/folder and returns its blocks to the Space Manager.
* `stat <name>`: Displays metadata and I/O Latency (CPU cycles).
* `policy`: View or switch the system operation mode.
* `history`: View the command history buffer.

🏗 Project Structure

* `/src/kernel`: Core kernel logic and shell implementation.
* `/src/kernel/fs`: CodaFS implementation, Telemetry hooks, and the Space Manager.
* `/src/kernel/drivers`: Hardware abstraction (VGA, Keyboard, ATA/IDE).

🛠 Roadmap

* ✅ **Phase 3: Shell Heuristics:** Predictive command suggestions and history browsing.
* ✅ **Phase 4 (Part A): Markov Brain:** Probabilistic command sequencing and ghost-text integration.
* ✅ **Phase 4 (Part B): Brain Persistence:** Successful serialization of transition tables to disk.
* ⏳ **Phase 5: The Sentinel:** Implementation of telemetry-driven self-healing logic (IO-to-Brain bridge).
* ⏳ **Adaptive Superblock:** Real-time Policy enforcement based on hardware health.
