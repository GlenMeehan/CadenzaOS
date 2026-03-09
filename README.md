CodaOS
A operating system built from scratch using the Zig programming language. CodaOS focuses on a clean, educational architecture with a custom filesystem and a responsive kernel-level shell.

🚀 Current Features
Micro-Kernel Foundation: Written in Zig, leveraging its type safety and manual memory management.
CodaFS: A custom-designed filesystem featuring:
Bitmap-based Space Management: Tracking disk allocation.
Extent-based Storage: Efficiently mapping file data to disk blocks.
Metadata Tagging: Detailed file information (size, type, and location).
Interactive Shell: A built-in CLI for system interaction.
VGA Driver: Direct hardware rendering for the console interface.

📂 Filesystem Commands
CodaOS uses a unique set of commands for file manipulation:
ls: List all files in the root directory.
mf <filename>: Make File – Creates a new file entry and allocates metadata.
wf <filename> "<text>": Write File – Allocates data blocks and commits text to disk.
cat <filename>: Concatenate – Reads data blocks and outputs content to the screen.
stat <filename>: Displays file metadata, including type, size, and LBA location.

🛠 Project Structure
/src/kernel: The core kernel logic and entry point.
/src/kernel/fs: The implementation of CodaFS, including the Space Manager and File structures.
/src/kernel/drivers: Hardware abstraction layers (VGA, Keyboard, Block Devices).
/src/kernel/shell.zig: The command-line interface logic.

🏗 Roadmap
[ ] Fix: Prevent block leakage on file overwrite.
[ ] Feature: Support for multi-block (large) files.
[ ] Driver: IDE/ATA support for true disk persistence.
[ ] Feature: df (Delete File) command.
