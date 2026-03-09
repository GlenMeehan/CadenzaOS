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
const config = @import("config.zig");
const codafs = @import("fs/coda_fs.zig");
const CodaFs = @import("fs/coda_fs.zig").CodaFs;
const bp = @import("fs/coda_fs.zig").breakpoint;
const coda_file = @import("fs/coda_file.zig");

const FG = 15;
const BG = 0;

var parse_tokens: [16][]const u8 = undefined;
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
    // 1. Validation: args[0] is "touch", args[1] should be the filename
    if (args.len < 2) {
        vga.writeString("Usage: touch <filename>\n", 15, 0);
        return;
    }

    const filename = args[1];

    // 2. Call the filesystem
    g_fs.createFile(g_allocator, filename) catch |err| {
        // We use a different color (maybe 12 for red?) if your VGA supports it,
        // otherwise stay with 15/0
        vga.writeString("Touch failed: ", 15, 0);
        vga.writeString(@errorName(err), 15, 0);
        vga.writeString("\n", 15, 0);
        return;
    };

    // 3. Success feedback
    vga.writeString("Created file: ", 15, 0);
    // Note: If filename is a slice, ensure your writeString handles slices
    vga.writeString(filename, 15, 0);
    vga.writeString("\n", 15, 0);
}

fn cmd_stat(args: [][]const u8) void {
    if (args.len < 2) {
        vga.writeString("Usage: stat <filename>\n", 15, 0);
        return;
    }

    const filename = args[1];

    const lba = g_fs.findFile(g_allocator, filename) catch {
        vga.writeString("File not found\n", 15, 0);
        return;
    };

    // Make sure this 'const meta' (or 'var meta') exists!
    const meta = g_fs.readFileMeta(g_allocator, lba) catch {
        vga.writeString("Failed to read metadata\n", 15, 0);
        return;
    };

    // --- Line 1: Filename ---
    // Using a buffer to keep "File: name" on one line
    var name_line: [64]u8 = undefined;
    const name_full = std.fmt.bufPrint(&name_line, "File: {s}", .{filename}) catch "File: [name error]";
    vga.writeString(name_full, 15, 0);

    // --- Line 2: Type ---
    if (meta.file_type == .File) {
        vga.writeString("Type: Regular File", 15, 0);
    } else {
        vga.writeString("Type: Directory", 15, 0);
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

    vga.writeString(size_line[0..cursor], 15, 0);
}

fn cmd_wf(args: [][]const u8) void {
    // 1. Validation: wf <filename> <text>
    if (args.len < 3) {
        vga.writeString("Usage: wf <filename> <text>\n", 15, 0);
        return;
    }

    const filename = args[1];
    // Create a buffer to hold the joined text (e.g., 256 bytes)
    var text_buf: [256]u8 = undefined;
    var current_pos: usize = 0;

    for (args[2..], 0..) |arg, i| {
        // Add a space between words, but not before the first word
        if (i > 0 and current_pos < text_buf.len) {
            text_buf[current_pos] = ' ';
            current_pos += 1;
        }

        // Copy the argument into our buffer
        for (arg) |char| {
            if (current_pos < text_buf.len) {
                text_buf[current_pos] = char;
                current_pos += 1;
            }
        }
    }
    // This is the string we will actually write to disk
    const text = text_buf[0..current_pos];

    // 2. Find the file's Metadata LBA
    const meta_lba = g_fs.findFile(g_allocator, filename) catch {
        vga.writeString("File not found\n", 15, 0);
        return;
    };

    // 3. Load the Metadata struct
    var meta = g_fs.readFileMeta(g_allocator, meta_lba) catch {
        vga.writeString("Error reading metadata\n", 15, 0);
        return;
    };

    // 4. Allocate a data block (since it's a new file)
    // We use the helper we just wrote!
    var data_lba: u64 = 0;

    // Logic: Reuse the first block if it exists, otherwise allocate
    if (meta.extent_count > 0) {
        // We take the start block of the first existing extent
        data_lba = meta.extents[0].start_block;
    } else {
        // The file is empty, so we must find fresh space
        data_lba = g_fs.appendBlockToFile(g_allocator, meta_lba, &meta) catch |err| {
            vga.writeString("Allocation failed: ", 15, 0);
            vga.writeString(@errorName(err), 15, 0);
            return;
        };
    }

    // 5. Write the text to that data block
    // We'll create a temporary buffer for the 512-byte block
    const block_buf = g_allocator.alloc(u8, 512) catch return;
    defer g_allocator.free(block_buf);
    @memset(block_buf, 0);

    // Copy the text into the block (cap it at 512 bytes for now)
    const write_len = if (text.len > 512) 512 else text.len;
    @memcpy(block_buf[0..write_len], text[0..write_len]);

    g_fs.device.writeBlocks(g_fs.device.ctx, data_lba, block_buf) catch {
        vga.writeString("Disk write failed\n", 15, 0);
        return;
    };

    // 6. Update the file size in the Metadata and save it
    meta.size_bytes = write_len;
    g_fs.writeBlockStruct(meta_lba, &meta, @sizeOf(coda_file.FileMeta)) catch {};

    vga.writeString("Wrote to ", 15, 0);
    vga.writeString(filename, 15, 0);
    vga.writeString("\n", 15, 0);
}

fn cmd_cat(args: [][]const u8) void {
    if (args.len < 2) {
        vga.writeString("Usage: cat <filename>\n", 15, 0);
        return;
    }

    const filename = args[1];

    // 1. Find the file
    const meta_lba = g_fs.findFile(g_allocator, filename) catch {
        vga.writeString("File not found\n", 15, 0);
        return;
    };

    // 2. Read the Metadata
    const meta = g_fs.readFileMeta(g_allocator, meta_lba) catch {
        vga.writeString("Error reading metadata\n", 15, 0);
        return;
    };

    // 3. Check if there is actually data to read
    if (meta.size_bytes == 0 or meta.extent_count == 0) {
        vga.writeString("(File is empty)\n", 15, 0);
        return;
    }

    // 4. Read the first data block
    // For now, we only support files that fit in one block (512 bytes)
    const data_lba = meta.extents[0].start_block;
    const buf = g_allocator.alloc(u8, 512) catch return;
    defer g_allocator.free(buf);

    g_fs.device.readBlocks(g_fs.device.ctx, data_lba, buf) catch {
        vga.writeString("Error reading data block\n", 15, 0);
        return;
    };

    // 5. Output the data
    // We only print up to size_bytes to avoid printing trailing zeros/garbage
    const display_size = if (meta.size_bytes > 512) 512 else meta.size_bytes;

    // Safety check: Ensure we don't try to print an empty slice
    if (display_size > 0) {
        vga.writeString(buf[0..display_size], 15, 0);
        vga.writeString("\n", 15, 0);
    }
}
