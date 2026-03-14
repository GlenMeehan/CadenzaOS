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


const FG = 15;
const BG = 0;

var parse_tokens: [conf.MAX_ARGS][]const u8 = undefined;
var g_fs: *CodaFs = undefined;
var g_allocator: std.mem.Allocator = undefined; // Add this line

fn parseArgs(line: []const u8) [][]const u8 {
    var count: usize = 0;
    var i: usize = 0;

    while (i < line.len) {
        while (i < line.len and line[i] == ' ') : (i += 1) {}
        if (i >= line.len) break;

        const start = i;

        while (i < line.len and line[i] != ' ') : (i += 1) {}

        parse_tokens[count] = line[start..i];
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
};

pub fn run(fs: *CodaFs, allocator: std.mem.Allocator) void {
    g_fs = fs;
    g_allocator = allocator;
    while (true) {
        vga.writeString("Cadenza> ",3, 0);
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
    const entries = g_fs.listDir(g_allocator, "/") catch |err| {
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
        const name = entry.name[0..entry.name_len];
        for (name) |c| {
            vga.putChar(c, FG, BG);
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
    g_fs.createFile(g_allocator, filename) catch |err| {
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

    const lba = g_fs.findFile(g_allocator, filename) catch {
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

    var text_buf: [conf.TERMINAL_LINE_SIZE]u8 align(16) = undefined;
    var current_pos: usize = 0;

    for (args[2..], 0..) |arg, i| {
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

    const meta_lba = g_fs.findFile(g_allocator, filename) catch {
        vga.writeString("Error: File not found\n", 12, 0);
        return;
    };

    var meta = g_fs.readFileMeta(g_allocator, meta_lba) catch {
        vga.writeString("Error: Could not read metadata\n", 12, 0);
        return;
    };

    // --- 4. AUTO-GROWTH LOGIC ---
    // Calculate how many blocks this text actually needs
    const blocks_needed = (final_text.len + (conf.BASE_IO_BUF_SIZE - 1)) / conf.BASE_IO_BUF_SIZE;

    // If we don't have enough blocks, ask the SpaceManager for more
    while (meta.extent_count < blocks_needed) {
        // We use the explicit Type.function(instance) call to avoid pointer ambiguity
        codafs.addBlockToFile(g_fs, g_allocator, &meta) catch |err| {
            if (err == error.FileAtMaximumSize) {
                vga.writeString("Warning: Truncating to 4KB limit.\n", 14, 0);
                break;
            }
            vga.writeString("Error: Disk full, growth failed.\n", 12, 0);
            return;
        };
    }

    // --- 5. UPDATE METADATA ---
    meta.size_bytes = @intCast(final_text.len);

    // --- 6. WRITE DATA BLOCKS ---
    const block_buf = g_allocator.alloc(u8, conf.BASE_IO_BUF_SIZE) catch {
        vga.writeString("Error: Out of memory\n", 12, 0);
        return;
    };
    defer g_allocator.free(block_buf);

    var bytes_written: usize = 0;
    var block_idx: usize = 0;

    // We loop through the text and map each block index to its specific extent
    while (bytes_written < final_text.len and block_idx < meta.extent_count) {
        @memset(block_buf, 0);
        const remaining = final_text.len - bytes_written;
        const copy_size = if (remaining > conf.BASE_IO_BUF_SIZE) conf.BASE_IO_BUF_SIZE else remaining;

        @memcpy(block_buf[0..copy_size], final_text[bytes_written .. bytes_written + copy_size]);

        // FIX: Look up the LBA from the correct extent
        const target_lba = meta.extents[block_idx].start_block;

        g_fs.device.writeBlocks(g_fs.device.ctx, target_lba, block_buf) catch {
            vga.writeString("Error: Disk write failed\n", 12, 0);
            return;
        };

        bytes_written += copy_size;
        block_idx += 1;
    }

    // 7. Persist the updated Metadata (size AND new extent list)
    g_fs.writeBlockStruct(meta_lba, &meta, @sizeOf(coda_file.FileMeta)) catch {
        vga.writeString("Error: Failed to update metadata\n", 12, 0);
        return;
    };

    vga.writeString("Success: File updated and grown.\n", 10, 0);
}

fn cmd_cat(args: [][]const u8) void {
    if (args.len < 2) {
        vga.writeString("Usage: cat <filename>\n", FG, BG);
        return;
    }

    const filename = args[1];

    // 1. Find the file
    const meta_lba = g_fs.findFile(g_allocator, filename) catch {
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

    // 4. Read and Output data blocks in a loop
    const buf = g_allocator.alloc(u8, 512) catch return;
    defer g_allocator.free(buf);

    var bytes_remaining = meta.size_bytes;

    // We loop through the extents (up to 8)
    for (meta.extents[0..meta.extent_count]) |extent| {
        if (bytes_remaining == 0) break;

        // Read the current block
        g_fs.device.readBlocks(g_fs.device.ctx, extent.start_block, buf) catch {
            vga.writeString("\nError reading data block\n", FG, BG);
            return;
        };

        // Calculate how much of this specific 512-byte block is actual file data
        const chunk_size = if (bytes_remaining > 512) @as(usize, 512) else bytes_remaining;

        // Output this chunk - we use a slice to ensure we don't print
        // the trailing 0s (nulls) that exist in the remainder of the 512-byte buffer.
        vga.writeRaw(buf[0..chunk_size], FG, BG);

        // Update our counter
        bytes_remaining -= chunk_size;
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

    g_fs.deleteFile(g_allocator, filename) catch |err| {
        if (err == error.FileNotFound) {
            vga.writeString("Error: File not found.\n", 12, 0);
        } else {
            vga.writeString("Error: Could not delete file.\n", 12, 0);
        }
        return;
    };

    vga.writeString("File deleted successfully.\n", 10, 0);
}
