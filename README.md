# CadenzaOS
An operating system built from scratch using the Zig programming language. CadenzaOS focuses on a clean, educational architecture with a custom filesystem and a responsive kernel-level shell.

## 🚀 Current Features
- **Monolithic-Kernel Foundation**: Written in Zig, leveraging its type safety and manual memory management.
- **CodaFS (Adaptive Hierarchy)**: A custom-designed, extent-based filesystem.
    - **Context-Aware Navigation**: Supports a tree-based directory structure with a Current Working Directory (CWD).
    - **Policy-Aware Superblock**: Hardware-level enums (Admin, Dev, Gaming) that dictate system behavior.
    - **I/O Telemetry**: Real-time monitoring of disk latency using CPU cycle counting (RDTSC).
    - **Write-Through Cache**: Uses a 4MB RAM workspace mirrored to physical ATA storage for instant performance.
- **Interactive Shell with Heuristics**: 
    - **Command History**: Circular buffer for navigating past inputs with arrow keys.
    - **Predictive Suggestions**: Early-stage heuristic engine that suggests "next steps" based on user intent.
- **VGA Driver**: Direct hardware rendering with support for 80x50 high-density text mode.

## 📂 Filesystem & System Commands
* `ls`: List all files and folders in the current directory.
* `cd <dir>`: Navigate the filesystem tree.
* `mkdir <name>`: Create a new subfolder.
* `mf / wf / cat`: File creation, writing, and reading.
* `rm <name>`: Deletes a file/folder and returns its blocks to the Space Manager.
* `stat <name>`: Displays metadata and **I/O Latency** (CPU cycles).
* `policy`: View or switch the system operation mode (e.g., Dev, Gaming).
* `history`: View the command history buffer.

## 🏗 Project Structure
* `/src/kernel`: Core kernel logic and shell implementation.
* `/src/kernel/fs`: CodaFS implementation, Telemetry hooks, and the Space Manager.
* `/src/kernel/drivers`: Hardware abstraction (VGA, Keyboard, ATA/IDE).

## 🛠 Roadmap
- [x] **Hierarchy & Persistence**: Full sub-directory support with ATA persistence.
- [x] **Phase 2: Adaptive Superblock**: Implementation of System Policies and I/O Telemetry.
- [x] **Phase 3: Shell Heuristics**: Predictive command suggestions and history browsing.
- [ ] **Phase 4: TinyML Integration**: Replacing hardcoded heuristics with a Markov Chain "Brain."
- [ ] **The Sentinel**: Self-healing logic triggered by telemetry anomalies.
