// src/kernel/shell.zig

// Simple line‑oriented shell for Cadenza OS.
// - No dynamic allocation
// - Commands are statically registered in `commands`
// - Input is provided by the terminal subsystem (`term`)
// - Commands receive tokenized arguments: [][]const u8
// - All output goes through VGA text mode

const std = @import("std");
const mem = @import("memory.zig");
const vga = @import("vga.zig");
const conv = @import("convert.zig");
const root = @import("kernel.zig");
const system = @import("system.zig");
const term = root.term;
const conf = @import("config.zig");
const codafs = @import("fs/coda_fs.zig");
const CodaFs = @import("fs/coda_fs.zig").CodaFs;
const bp = @import("fs/coda_fs.zig").breakpoint;
const coda_file = @import("fs/coda_file.zig");
const ata = @import("drivers/ata.zig");


const DirEntry = coda_file.DirEntry;
const Directory = coda_file.Directory; // Do this for Directory too!

const FG = 15;
const BG = 0;

var parse_tokens: [conf.MAX_ARGS][]const u8 = undefined;
var g_fs: *CodaFs = undefined;
var g_allocator: std.mem.Allocator = undefined; // Add this line
var g_cwd_lba: u64 = 0;
var g_cwd_blocks: u32 = 0;
var g_cwd_name: [32]u8 = undefined;
var g_cwd_name_len: usize = 1; // Start with "/"


fn parseArgs(line: []const u8) [][]const u8 {
    var count: usize = 0;
    var i: usize = 0;

    while (i < line.len) {
        // 1. Skip any leading spaces between tokens
        while (i < line.len and line[i] == ' ') : (i += 1) {}
        if (i >= line.len) break;

        if (line[i] == '"') {
            // --- QUOTED TOKEN ---
            i += 1; // Skip the opening quote
            const start = i;

            // Consume everything until the closing quote or end of line
            while (i < line.len and line[i] != '"') : (i += 1) {}

            parse_tokens[count] = line[start..i];

            // Move past the closing quote if it exists
            if (i < line.len and line[i] == '"') i += 1;
        } else {
            // --- NORMAL TOKEN ---
            const start = i;
            // Consume until the next space
            while (i < line.len and line[i] != ' ') : (i += 1) {}

            parse_tokens[count] = line[start..i];
        }

        count += 1;
        if (count >= parse_tokens.len) break;
    }

    return parse_tokens[0..count];
}

const Command = struct {
    name: []const u8,
    desc: []const u8,
    func: *const fn([][]const u8) void,
};

const commands = [_]Command{
    .{ .name = "help",    .desc = "Show this help message", .func = cmd_help },
    .{ .name = "clear",   .desc = "Clear the screen",       .func = cmd_clear },
    .{ .name = "echo",    .desc = "Print arguments",        .func = cmd_echo },
    .{ .name = "history", .desc = "Show command history",   .func = cmd_history },
    .{ .name = "shutdown", .desc = "Power off the machine", .func = cmd_shutdown },
    .{ .name = "reboot",   .desc = "Reboot the machine",    .func = cmd_reboot },
    .{ .name = "ls",       .desc = "List root directory",    .func = cmd_ls },
    .{ .name = "mf",       .desc = "Create a file",    .func = cmd_mf },
    .{ .name = "wf",       .desc = "Write data into file",    .func = cmd_wf },
    .{ .name = "rm",       .desc = "Delete a file",    .func = cmd_rm },
    .{ .name = "stat",       .desc = "Read file details",    .func = cmd_stat },
    .{ .name = "cat",       .desc = "Print contents of a file",    .func = cmd_cat },
    .{ .name = "rename",       .desc = "Rename a file",    .func = cmd_rename },
    .{ .name = "mkdir",       .desc = "Create a directory / folder",    .func = cmd_mkdir },
    .{ .name = "cd",       .desc = "Navigate to a new folder",    .func = cmd_cd },
};

pub fn run(fs: *CodaFs, allocator: std.mem.Allocator) void {
    g_fs = fs;
    g_allocator = allocator;
    g_cwd_lba = fs.superblock.root_dir_extent_start;
    g_cwd_blocks = @intCast(fs.superblock.root_dir_extent_blocks);

    // Initialize the name to root
    g_cwd_name[0] = '/';
    g_cwd_name_len = 1;

    while (true) {
        // 1. Prepare a buffer for the prompt
        var prompt_buf: [64]u8 = undefined;

        // 2. Format the string: "Cadenza [/FolderLBA]> "
        // If you haven't implemented path strings yet, LBA is a great "Pro" view
        const current_dir = g_cwd_name[0..g_cwd_name_len];
        const prompt = std.fmt.bufPrint(&prompt_buf, "Cadenza {s}> ", .{current_dir}) catch "Cadenza> ";

        // 3. Write the dynamic prompt
        vga.writeString(prompt, 3, 0);

        vga.updateCursorHardware();
        term.startNewLine();

        while (true) {
            if (term.takeLine()) |line| {
                term.commitHistory();
                execute(line);
                term.consumeLine();
                break;
            }
        }
    }
}

fn execute(line: []const u8) void {
    const tokens = parseArgs(line);

    if (tokens.len == 0) return;

    const cmd = tokens[0];

    for (commands) |c| {
        //while (true) asm volatile ("cli; hlt");
        if (mem.eqlNoSimd(u8, c.name, cmd)) {
            c.func(tokens);
            return;
        }
    }

    vga.writeString("Unknown command\n", FG, BG);
}

fn cmd_ls(_: [][]const u8) void {
    const entries = g_fs.listDir(g_allocator, g_cwd_lba, g_cwd_blocks) catch |err| {
        vga.writeString("ls failed: ", FG, BG);
        vga.writeString(@errorName(err), FG, BG);
        vga.putChar('\n', FG, BG);
        return;
    };

    defer g_allocator.free(entries);

    if (entries.len == 0) {
        vga.writeString("(empty)\n", FG, BG);
        return;
    }

    for (entries) |entry| {
        // 1. Fetch the metadata to check the type
        // If this fails, we just skip this entry and move to the next
        const meta = g_fs.readFileMeta(g_allocator, entry.meta_extent.start_block) catch continue;

        // 2. Print a prefix based on the type
        if (meta.file_type == .Directory) {
            vga.writeString("[DIR]  ", 11, BG); // 11 is usually Cyan/Light Blue
        } else {
            vga.writeString("[FILE] ", FG, BG);
        }

        // 3. Print the name (your existing logic)
        const name = entry.name[0..entry.name_len];
        for (name) |c| {
            vga.putChar(c, (if (meta.file_type == .Directory) @as(u8, 11) else FG), BG);
        }

        // 4. Add a trailing slash for directories to make it extra clear
        if (meta.file_type == .Directory) {
            vga.putChar('/', 11, BG);
        }

        vga.putChar('\n', FG, BG);
    }
}

fn cmd_help(_: [][]const u8) void {
    vga.writeString("Commands:", FG, BG);

    for (commands) |c| {
        vga.putChar('\n', FG, BG);
        vga.writeRaw("  ", FG, BG);
        vga.writeRaw(c.name, FG, BG);
        vga.writeRaw(" - ", FG, BG);
        vga.writeRaw(c.desc, FG, BG);
    }

    vga.putChar('\n', FG, BG);
    vga.putChar('\n', FG, BG);

    vga.writeString("Keyboard shortcuts:", FG, BG);

    const shortcuts = [_][]const u8{
        "  Esc        Cancel the current line",
        "  Tab        Insert 4 spaces",
        "  < >        Move cursor left/right",
        "  ^ v        Browse history",
        "  Home       Move to start of line",
        "  End        Move to end of line",
    };

    for (shortcuts) |s| {
        vga.putChar('\n', FG, BG);
        vga.writeRaw(s, FG, BG);
    }

    vga.putChar('\n', FG, BG);
    vga.putChar('\n', FG, BG);

    vga.writeString("Ctrl shortcuts:", FG, BG);

    const ctrls = [_][]const u8{
        "  Ctrl-A     Move to start of line",
        "  Ctrl-E     Move to end of line",
        "  Ctrl-U     Delete from cursor to start",
        "  Ctrl-K     Delete from cursor to end",
        "  Ctrl-W     Delete previous word",
        "  Ctrl-L     Clear screen",
        "  Ctrl-C     Abort current line",
    };

    for (ctrls) |s| {
        vga.putChar('\n', FG, BG);
        vga.writeRaw(s, FG, BG);
    }

    vga.putChar('\n', FG, BG);
}

fn cmd_clear(_: [][]const u8) void {
    vga.clearScreen(FG, BG);
}

fn cmd_echo(args: [][]const u8) void {
    var i: usize = 1;

    while (i < args.len) : (i += 1) {
        const word = args[i];

        var j: usize = 0;
        while (j < word.len) : (j += 1) {
            vga.putChar(word[j], FG, BG);
        }

        if (i + 1 < args.len) {
            vga.putChar(' ', FG, BG);
        }
    }

    vga.putChar('\n', FG, BG);
}

fn cmd_test(_: [][]const u8) void {
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        vga.putChar('#', FG, BG);
    }
    vga.putChar('\n', FG, BG);
}

fn cmd_history(_: [][]const u8) void {
    if (term.history_len == 0) {
        vga.writeString("No history\n", FG, BG);
        return;
    }

    var i: usize = 0;
    while (i < term.history_len) : (i += 1) {
        if (term.getHistoryEntry(i)) |line| {
            vga.writeString(line, FG, BG);
            vga.putChar('\n', BG, FG);
        }
    }
}

fn cmd_shutdown(_: [][]const u8) void {
    vga.writeString("Shutting down...\n", FG, BG);
    system.shutdown();
}

fn cmd_reboot(_: [][]const u8) void {
    vga.writeString("Rebooting...\n", FG, BG);
    system.reboot();
}

fn cmd_mf(args: [][]const u8) void {
    // 1. Validation: args[0] is "mf", args[1] should be the filename
    if (args.len < 2) {
        vga.writeString("Usage: mf <filename>\n", FG, BG);
        return;
    }

    const filename = args[1];

    // 2. Call the filesystem
    g_fs.createFile(g_allocator, g_cwd_lba, g_cwd_blocks, filename) catch |err| {
        // We use a different color (maybe 12 for red?) if your VGA supports it,
        // otherwise stay with 15/0
        vga.writeString("mf failed: ", FG, BG);
        vga.writeString(@errorName(err), FG, BG);
        vga.writeString("\n", FG, BG);
        return;
    };

    // 3. Success feedback
    vga.writeString("Created file: ", FG, BG);
    // Note: If filename is a slice, ensure your writeString handles slices
    vga.writeString(filename, FG, BG);
    vga.writeString("\n", FG, BG);
}

fn cmd_stat(args: [][]const u8) void {
    if (args.len < 2) {
        vga.writeString("Usage: stat <filename>\n", FG, BG);
        return;
    }

    const filename = args[1];

    const lba = g_fs.findFile(g_allocator, g_cwd_lba, filename) catch {
        vga.writeString("File not found\n", FG, BG);
        return;
    };

    // Make sure this 'const meta' (or 'var meta') exists!
    const meta = g_fs.readFileMeta(g_allocator, lba) catch {
        vga.writeString("Failed to read metadata\n", FG, BG);
        return;
    };

    // --- Line 1: Filename ---
    // Using a buffer to keep "File: name" on one line
    var name_line: [64]u8 = undefined;
    const name_full = std.fmt.bufPrint(&name_line, "File: {s}", .{filename}) catch "File: [name error]";
    vga.writeString(name_full, FG, BG);

    // --- Line 2: Type ---
    if (meta.file_type == .File) {
        vga.writeString("Type: Regular File", FG, BG);
    } else {
        vga.writeString("Type: Directory", FG, BG);
    }

    // --- Line 3: Size (Manual Stitching) ---
    var size_num_buf: [16]u8 = undefined;
    // Cast size_bytes to u32 for your conv function
    const size_str = conv.u32ToStr(&size_num_buf, @intCast(meta.size_bytes));

    var size_line: [64]u8 = undefined;
    @memset(&size_line, 0);

    const label = "Size: ";
    const suffix = " bytes";

    var cursor: usize = 0;
    @memcpy(size_line[cursor..label.len], label);
    cursor += label.len;

    @memcpy(size_line[cursor .. cursor + size_str.len], size_str);
    cursor += size_str.len;

    @memcpy(size_line[cursor .. cursor + suffix.len], suffix);
    cursor += suffix.len;

    vga.writeString(size_line[0..cursor], FG, BG);
}

fn cmd_wf(args: [][]const u8) void {
    if (args.len < 3) {
        vga.writeString("Usage: wf <filename> <text>\n", 15, 0);
        return;
    }

    const filename = args[1];

    // --- 1. COLLECT TEXT FROM ARGS ---
    var text_buf: [conf.TERMINAL_LINE_SIZE]u8 align(16) = undefined;
    var current_pos: usize = 0;
    for (args[2..], 0..) |arg, i| {
        // Add a space BEFORE every word except the very first one
        if (i > 0 and current_pos < text_buf.len) {
            text_buf[current_pos] = ' ';
            current_pos += 1;
        }

        const space_left = text_buf.len - current_pos;
        const copy_len = if (arg.len > space_left) space_left else arg.len;
        @memcpy(text_buf[current_pos .. current_pos + copy_len], arg[0..copy_len]);
        current_pos += copy_len;
    }
    const final_text = text_buf[0..current_pos];

    // --- 2. FIND OR CREATE THE FILE ---
    var meta_lba: u64 = 0;

    // Try to find it first
    if (g_fs.findFile(g_allocator, g_cwd_lba, filename)) |found_lba| {
        meta_lba = found_lba;
    } else |_| {
        // If not found, call your 3-argument createFile
    g_fs.createFile(g_allocator, g_cwd_lba, g_cwd_blocks, filename) catch {
            vga.writeString("Error: Could not create file\n", 12, 0);
            return;
        };
        // Now lookup the LBA of the file we just made
        meta_lba = g_fs.findFile(g_allocator, g_cwd_lba, filename) catch {
            vga.writeString("Error: File created but not found\n", 12, 0);
            return;
        };
    }

    // Load the actual metadata structure
    var meta = g_fs.readFileMeta(g_allocator, meta_lba) catch {
        vga.writeString("Error: Could not read metadata\n", 12, 0);
        return;
    };

    // --- 3. AUTO-GROWTH (APPEND-AWARE) ---
    const old_size = meta.size_bytes;
    const total_new_size = old_size + final_text.len;
    // Calculate total blocks needed for the combined data
    const total_blocks_needed = (total_new_size + 511) / 512;

    while (meta.extent_count < total_blocks_needed) {
        codafs.addBlockToFile(g_fs, g_allocator, &meta) catch |err| {
            if (err == error.FileAtMaximumSize) {
                vga.writeString("Warning: File capped at 4KB.\n", 14, 0);
                break;
            }
            vga.writeString("Error: Disk full.\n", 12, 0);
            return;
        };
    }

    // --- 4. DATA WRITE (READ-MODIFY-WRITE) ---
    const block_buf = g_allocator.alloc(u8, 512) catch return;
    defer g_allocator.free(block_buf);

    var bytes_to_append = final_text.len;
    var write_offset: usize = old_size;

    while (bytes_to_append > 0) {
        const block_idx = write_offset / 512;
        const offset_in_block = write_offset % 512;

        // Use your getLbaForBlock helper here
        const target_lba = getLbaForBlock(meta, block_idx);

        // READ the block so we don't destroy existing data
        g_fs.device.readBlocks(g_fs.device.ctx, target_lba, block_buf) catch {
            vga.writeString("Error: Read failed\n", 12, 0);
            return;
        };

        const space_in_block = 512 - offset_in_block;
        const copy_size = if (bytes_to_append > space_in_block) space_in_block else bytes_to_append;

        const source_start = final_text.len - bytes_to_append;
        @memcpy(block_buf[offset_in_block .. offset_in_block + copy_size],
                final_text[source_start .. source_start + copy_size]);

        // WRITE the updated block back to disk
        g_fs.device.writeBlocks(g_fs.device.ctx, target_lba, block_buf) catch {
            vga.writeString("Error: Write failed\n", 12, 0);
            return;
        };

        write_offset += copy_size;
        bytes_to_append -= copy_size;
    }

    // --- 5. FINALIZE ---
    meta.size_bytes = @intCast(total_new_size);
    g_fs.writeBlockStruct(meta_lba, &meta, @sizeOf(coda_file.FileMeta)) catch {
        vga.writeString("Error: Metadata sync failed\n", 12, 0);
        return;
    };

    vga.writeString("Success: Data appended to Coda FS.\n", 10, 0);
}

fn cmd_cat(args: [][]const u8) void {
    if (args.len < 2) {
        vga.writeString("Usage: cat <filename>\n", FG, BG);
        return;
    }

    const filename = args[1];

    // 1. Find the file
    const meta_lba = g_fs.findFile(g_allocator, g_cwd_lba, filename) catch {
        vga.writeString("File not found\n", FG, BG);
        return;
    };

    // 2. Read the Metadata
    const meta = g_fs.readFileMeta(g_allocator, meta_lba) catch {
        vga.writeString("Error reading metadata\n", FG, BG);
        return;
    };

    // 3. Check if there is actually data to read
    if (meta.size_bytes == 0) {
        vga.writeString("(File is empty)\n", FG, BG);
        return;
    }

    // 4. Read and Output data blocks using nested loops
    const buf = g_allocator.alloc(u8, 512) catch return;
    defer g_allocator.free(buf);

    var bytes_remaining = meta.size_bytes;

    // Outer Loop: Iterate through the Extents
    for (meta.extents[0..meta.extent_count]) |extent| {
        if (bytes_remaining == 0) break;

        // Inner Loop: Iterate through the Blocks within this specific Extent
        var block_idx: u64 = 0;
        while (block_idx < extent.block_count and bytes_remaining > 0) : (block_idx += 1) {

            // Read exactly one block at a time into our 512-byte buffer
            const current_lba = extent.start_block + block_idx;
            g_fs.device.readBlocks(g_fs.device.ctx, current_lba, buf) catch {
                vga.writeString("\nError reading data block\n", FG, BG);
                return;
            };

            // Calculate how much of THIS block is data
            const chunk_size = if (bytes_remaining > 512) @as(usize, 512) else @as(usize, @intCast(bytes_remaining));

            // Output ONLY the data part
            vga.writeRaw(buf[0..chunk_size], FG, BG);

            bytes_remaining -= chunk_size;
        }
    }

    // Only add the newline once the entire file (all blocks) is finished
    vga.writeString("\n", FG, BG);
}
fn cmd_rm(args: [][]const u8) void {
    if (args.len < 2) {
        vga.writeString("Usage: rm <filename>\n", FG, BG);
        return;
    }

    const filename = args[1];

    g_fs.deleteFile(g_allocator, g_cwd_lba, filename) catch |err| {
        if (err == error.FileNotFound) {
            vga.writeString("Error: File not found.\n", 12, 0);
        } else {
            vga.writeString("Error: Could not delete file.\n", 12, 0);
        }
        return;
    };

    vga.writeString("File deleted successfully.\n", 10, 0);
}

fn cmd_rename(args: [][]const u8) void {
    if (args.len < 3) {
        vga.writeString("Usage: rename <old_name> <new_name>\n", 15, 0);
        return;
    }

    const old_name = args[1];
    const new_name = args[2];

    // 1. LOAD: Use g_cwd_blocks instead of root_dir_extent_blocks
    const dir_size = g_cwd_blocks * g_fs.device.block_size;
    const dir_buf = g_allocator.alloc(u8, dir_size) catch return;
    defer g_allocator.free(dir_buf);

    // 2. READ: Pull from g_cwd_lba, NOT root_lba
    g_fs.device.readBlocks(g_fs.device.ctx, g_cwd_lba, dir_buf) catch {
        vga.writeString("Error: Failed to read directory from disk.\n", 12, 0);
        return;
    };

    // 3. MAP: (Same logic, now mapped to the correct buffer)
    const entry_count = dir_size / @sizeOf(DirEntry);
    const entries = @as([*]DirEntry, @ptrCast(@alignCast(dir_buf.ptr)))[0..entry_count];
    var dir = Directory{ .entries = entries };

    // 4. MODIFY: Perform the rename in memory
    dir.renameEntry(old_name, new_name) catch |err| {
        if (err == error.FileNotFound) {
            vga.writeString("Error: File not found.\n", 12, 0);
        } else if (err == error.NameAlreadyExists) {
            vga.writeString("Error: New name already exists.\n", 12, 0);
        } else {
            vga.writeString("Error: Rename failed.\n", 12, 0);
        }
        return;
    };

    // 5. FLUSH: Manual write-back
    // Note: We avoid g_fs.flushDirectory because that likely still targets Root.
    // Writing directly to g_cwd_lba ensures the change stays in this folder.
    g_fs.device.writeBlocks(g_fs.device.ctx, g_cwd_lba, dir_buf) catch {
        vga.writeString("Error: Failed to sync changes to disk.\n", 12, 0);
        return;
    };

    vga.writeString("Successfully renamed file.\n", 10, 0);
}

fn cmd_mkdir(args: [][]const u8) void {
    if (args.len < 2) {
        vga.writeString("Usage: mkdir <dirname>\n", 15, 0);
        return;
    }

    const dir_name = args[1];

    // We call the new generalized function with the Directory type
    g_fs.createEntry(g_allocator, g_cwd_lba, g_cwd_blocks, dir_name, .Directory) catch |err| {
        if (err == error.AlreadyExists) {
            vga.writeString("Error: Name already taken.\n", 12, 0);
        } else {
            vga.writeString("Error: Could not create directory.\n", 12, 0);
        }
        return;
    };

    vga.writeString("Directory created successfully.\n", 10, 0);
}
fn cmd_cd(args: [][]const u8) void {
    if (args.len < 2) {
        vga.writeString("Usage: cd <directory>\n", 14, 0);
        return;
    }
    const target_name = args[1];

    // --- Special Case: Go Home ---
    if (std.mem.eql(u8, target_name, "/")) {
        g_cwd_lba = g_fs.superblock.root_dir_extent_start;
        g_cwd_blocks = @intCast(g_fs.superblock.root_dir_extent_blocks);
        g_cwd_name[0] = '/';
        g_cwd_name_len = 1;
        vga.writeString("Returned to Root.\n", 10, 0);
        return;
    }

    const entries = g_fs.listDir(g_allocator, g_cwd_lba, g_cwd_blocks) catch {
        vga.writeString("Error: Could not read directory.\n", 12, 0);
        return;
    };
    defer g_allocator.free(entries);

    for (entries) |entry| {
        const name = entry.name[0..entry.name_len];
        if (std.mem.eql(u8, name, target_name)) {
            const meta = g_fs.readFileMeta(g_allocator, entry.meta_extent.start_block) catch {
                vga.writeString("Error: Could not read metadata.\n", 12, 0);
                return;
            };

            if (meta.file_type == .Directory) {
                // Update LBA
                g_cwd_lba = meta.extents[0].start_block;
                g_cwd_blocks = @intCast(meta.extents[0].block_count);

                // --- NEW: Update the Name for the Prompt ---
                g_cwd_name[0] = '/';
                const copy_len = if (target_name.len > 30) 30 else target_name.len;
                @memcpy(g_cwd_name[1..1 + copy_len], target_name[0..copy_len]);
                g_cwd_name_len = 1 + copy_len;

                vga.writeString("Changed directory.\n", 10, 0);
                return;
            } else {
                vga.writeString("Error: Target is a file, not a directory.\n", 12, 0);
                return;
            }
        }
    }

    vga.writeString("Error: Directory not found.\n", 12, 0);
}


fn getLbaForBlock(meta: coda_file.FileMeta, block_index: u64) u64 {
    var blocks_seen: u64 = 0;
    for (meta.extents[0..meta.extent_count]) |extent| {
        if (block_index < blocks_seen + extent.block_count) {
            const offset_in_extent = block_index - blocks_seen;
            return extent.start_block + offset_in_extent;
        }
        blocks_seen += extent.block_count;
    }
    return 0;
}
