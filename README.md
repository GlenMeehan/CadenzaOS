# CadenzaOS
An operating system built from scratch using the Zig programming language. CadenzaOS focuses on a clean, educational architecture with a custom filesystem and a responsive kernel-level shell.

## 🚀 Current Features
- **Monolithic-Kernel Foundation**: Written in Zig, leveraging its type safety and manual memory management.
- **CodaFS (Hierarchical Version)**: A custom-designed, extent-based filesystem.
    - **Context-Aware Navigation**: Supports a tree-based directory structure with a Current Working Directory (CWD).
    - **Write-Through Cache**: Uses a 4MB RAM workspace mirrored to physical ATA storage for instant performance and true persistence.
    - **Extent-based Storage**: Efficiently maps file data to disk blocks.
    - **Dynamic Directory Geometry**: Supports multi-block directory extents to prevent entry overflows.
- **Interactive Shell**: A built-in CLI for system interaction with a dynamic prompt.
- **VGA Driver**: Direct hardware rendering for the console interface.

## 📂 Filesystem Commands
CadenzaOS uses a unique set of commands for file manipulation:
* `ls`: List all files and folders in the current directory.
* `cd <dir>`: **Change Directory** – Navigate the filesystem tree.
* `mkdir <name>`: **Make Directory** – Create a new subfolder.
* `mf <name>`: **Make File** – Creates a new file entry and allocates metadata.
* `wf <name> "text"`: **Write File** – Allocates data blocks and commits text to disk (supports auto-growth).
* `cat <name>`: **Concatenate** – Reads data blocks and outputs content to the screen.
* `rm <name>`: **Remove File** – Deletes a file/folder and returns its blocks to the Space Manager.
* `stat <name>`: Displays file metadata, including type, size, and LBA location.

## 🏗 Project Structure
* `/src/kernel`: The core kernel logic and entry point.
* `/src/kernel/fs`: The implementation of CodaFS, including the Space Manager and Write-Through RamDisk.
* `/src/kernel/drivers`: Hardware abstraction layers (VGA, Keyboard, ATA/IDE).

## 🛠 Roadmap
- [x] **Persistence**: IDE/ATA support via Write-Through caching.
- [x] **Deletion**: `rm` command with block reclamation.
- [x] **Hierarchy**: Full sub-directory support (`mkdir`, `cd`).
- [x] **Multi-Block Files**: Support for files larger than a single block (512 bytes).
- [ ] **Feature**: `cp` (copy) and `mv` (move) commands.
- [ ] **Sentinel AI**: Kernel-level integrity monitor for recursive filesystem checks.
- [ ] **Optimization**: Extent merging in the Space Manager to reduce fragmentation.
