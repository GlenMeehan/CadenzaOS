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
const coda = @import("fs/simplefs.zig");
const config = @import("config.zig");
const SimpleFS = coda.SimpleFS;
const Superblock = coda.Superblock;
const DirEntry = coda.DirEntry;
const entryNameSlice = coda.entryNameSlice;


const fs = &root.simplefs;
const FG = 15;
const BG = 0;

// Reused buffer for argument parsing.
// Shell is single-threaded, so this is safe.
var parse_tokens: [16][]const u8 = undefined;

// Tokenize a command line into at most 16 space‑separated tokens.
// No quoting, no escaping — this is intentional for simplicity.
fn parseArgs(line: []const u8) [][]const u8 {
    var count: usize = 0;
    var i: usize = 0;

    while (i < line.len) {
        // Skip spaces
        while (i < line.len and line[i] == ' ') : (i += 1) {}
        if (i >= line.len) break;

        const start = i;

        // Find end of token
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

// Static command registry. Commands must be pure functions taking [][]const u8.
const commands = [_]Command{
    .{ .name = "help",    .desc = "Show this help message", .func = cmd_help },
    .{ .name = "clear",   .desc = "Clear the screen",       .func = cmd_clear },
    .{ .name = "echo",    .desc = "Print arguments",        .func = cmd_echo },
    .{ .name = "history", .desc = "Show command history",   .func = cmd_history },
    .{ .name = "shutdown", .desc = "Power off the machine", .func = cmd_shutdown },
    .{ .name = "reboot",   .desc = "Reboot the machine",    .func = cmd_reboot },
    .{ .name = "fs",   .desc = "Coda FS info",    .func = cmd_fsinfo },
    .{ .name = "touch", .desc = "Create an empty file", .func = cmd_touch },
    .{ .name = "ls", .desc = "List directory contents", .func = cmd_ls },
    .{ .name = "write", .desc = "Write text to a file", .func = cmd_write },
    .{ .name = "cat", .desc = "Print file contents", .func = cmd_cat },
    .{ .name = "bmtest", .desc = "Print file contents", .func = cmd_bmtest },
    .{ .name = "freeblock", .desc = "Freeblock", .func = cmd_freeblock },
    .{ .name = "dumpbitmap", .desc = "Dumpblock", .func = cmd_dumpbitmap },
    .{ .name = "del", .desc = "Delete a file", .func = cmd_delete },
    .{ .name = "dbset", .desc = "Debug setblocks", .func = cmd_debug_setblocks },
    .{ .name = "testblocks", .desc = "Test block calculations", .func = cmd_testblocks },
};

// Main shell loop:
// 1. Print prompt
// 2. Wait for terminal to produce a full line
// 3. Execute command
// 4. Reset terminal state// Main shell loop:
// 1. Print prompt
// 2. Wait for terminal to produce a full line
// 3. Execute command
// 4. Reset terminal state
pub fn run() void {
    while (true) {
        vga.writeString("Cadenza> ",3, 0);
        vga.updateCursorHardware();

        // Tell the terminal a new prompt has been printed
        term.startNewLine();
        while (true) {

            if (term.takeLine()) |line| {
                term.commitHistory();
                //vga.putChar('\n', FG, BG);
                execute(line);
                term.consumeLine();     // now reset terminal state
                break;
            }
        }
    }
}

// Linear search through the command table.
// This is fine for <50 commands; no need for hashing yet.
fn execute(line: []const u8) void {
    const tokens = parseArgs(line);

    if (tokens.len == 0) return;

    const cmd = tokens[0];

    for (commands) |c| {
        if (std.mem.eql(u8, c.name, cmd)) {
            c.func(tokens);
            return;
        }
    }

    vga.writeString("Unknown command\n", FG, BG);
}

// Print all commands with descriptions.
// Uses writeRaw to avoid formatting overhead.
fn cmd_help(_: [][]const u8) void {
    vga.writeString("Commands:", FG, BG);

    for (commands) |c| {
        // Start a new line for each command
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

// Echo arguments separated by spaces.
// Does not interpret quotes or escapes.
fn cmd_echo(args: [][]const u8) void {
    // Start echo output on a fresh line
    //vga.putChar('\n', FG, BG);

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

// Print command history stored by the terminal subsystem.
// History entries are immutable slices owned by `term`.
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

// Print superblock fields in hex for debugging.
fn cmd_fsinfo(_: [][]const u8) void {
    var sb: coda.Superblock = undefined;

    fs.readSuperblock(&sb) catch {
        vga.writeString("Failed to read superblock\n", FG, BG);
        return;
    };
    var buf: [config.BASE_IO_BUF_SIZE]u8 = undefined;
    vga.writeString("CodaFS info:\n", FG, BG);

    vga.writeRaw("  Magic: ", FG, BG);
    vga.writeRaw(conv.toHex(u64, sb.magic, &buf), FG, BG);
    vga.putChar('\n', FG, BG);

    vga.writeRaw("  Version: ", FG, BG);
    vga.writeRaw(conv.toHex(u64, sb.version, &buf), FG, BG);
    vga.putChar('\n', FG, BG);

    vga.writeRaw("  Block size: ", FG, BG);
    vga.writeRaw(conv.toHex(u64, sb.block_size, &buf), FG, BG);
    vga.putChar('\n', FG, BG);

    vga.writeRaw("  Total blocks: ", FG, BG);
    vga.writeRaw(conv.toHex(u64, sb.total_blocks, &buf), FG, BG);
    vga.putChar('\n', FG, BG);

    vga.writeRaw("  Bitmap start: ", FG, BG);
    vga.writeRaw(conv.toHex(u64, sb.bitmap_start, &buf), FG, BG);
    vga.putChar('\n', FG, BG);

    vga.writeRaw("  Bitmap blocks: ", FG, BG);
    vga.writeRaw(conv.toHex(u64, sb.bitmap_blocks, &buf), FG, BG);
    vga.putChar('\n', FG, BG);

    vga.writeRaw("  Root dir block: ", FG, BG);
    vga.writeRaw(conv.toHex(u64, sb.root_dir_block, &buf), FG, BG);
    vga.putChar('\n', FG, BG);
}

// Create an empty file in the root directory.
// Does not allocate data blocks yet.
fn cmd_touch(args: [][]const u8) void {
    if (args.len < 2) {
        vga.writeString("Usage: touch <filename>\n", FG, BG);
        return;
    }

    const name = args[1];

    coda.createFile(fs, name) catch |err| {
        if (err == error.InvalidName) {
            vga.writeString("you cannot use that file name\n", FG, BG);
        }else if (err == error.FileExists) {
            vga.writeString("touch: file already exists\n", FG, BG);

        } else {
            vga.writeString("touch: failed to create file\n", FG, BG);
        }
        return;
    };

    vga.writeString("File created\n", FG, BG);
}

// List files in the root directory.
// Directory block is a packed array of DirEntry structs.
// NOTE: e.name is a fixed-size array; we stop at the first zero byte.
fn cmd_ls(_: [][]const u8) void {
    var sb: coda.Superblock = undefined;
    fs.readSuperblock(&sb) catch {
        vga.writeString("Failed to read superblock\n", 15, 0);
        return;
    };

    var dir_block: [512]u8 align(@alignOf(coda.DirEntry)) = undefined;
    fs.backend.readBlocksImpl(sb.root_dir_block, dir_block[0..]) catch return;

    const entry_count = sb.block_size / @sizeOf(coda.DirEntry);
    const entry_ptr: [*]coda.DirEntry = @ptrCast(&dir_block);
    const entries = entry_ptr[0..entry_count];

    for (entries) |e| {
        if (e.name[0] == 0) continue;

        // Compute name length safely
        vga.writeRaw(&e.name, FG, BG);
        vga.writeRaw("  ", FG, BG);

        vga.writeRaw("size=", FG, BG);
        var size_buf: [16]u8 = undefined;
        const size_str = conv.u32ToStr(&size_buf, e.size_bytes);
        vga.writeRaw(size_str, FG, BG);
        vga.writeRaw("  ", FG, BG);

        vga.writeRaw("block=", FG, BG);
        var blk_buf: [16]u8 = undefined;
        const blk_str = conv.u32ToStr(&blk_buf, e.start_block);
        vga.writeRaw(blk_str, FG, BG);
        vga.writeRaw("  ", FG, BG);

        vga.writeRaw("count=", FG, BG);
        var cnt_buf: [16]u8 = undefined;
        const cnt_str = conv.u32ToStr(&cnt_buf, e.block_count);
        vga.writeRaw(cnt_str, FG, BG);

        vga.putChar('\n', FG, BG);
    }
}

fn cmd_write(args: [][]const u8) void {
    if (args.len < 3) {
        vga.writeString("Usage: write <file> <text>\n", 15, 0);
        return;
    }

    const filename = args[1];
    // Build the full text from args[2..]
    var buf: [config.TERMINAL_LINE_SIZE]u8 = undefined; // or BASE_IO_BUF_SIZE * 8
    var pos: usize = 0;

    var i: usize = 2;
    while (i < args.len and pos < buf.len) : (i += 1) {
        const word = args[i];

        if (pos + word.len > buf.len) break;

        _ = mem.memcpy(
            @ptrCast(&buf[pos]),
                       @ptrCast(word.ptr),
                       word.len,
        );
        pos += word.len;

        if (i + 1 < args.len and pos < buf.len) {
            buf[pos] = ' ';
            pos += 1;
        }
    }

    const text = buf[0..pos];

    // Load superblock
    var sb: coda.Superblock = undefined;
    fs.readSuperblock(&sb) catch {
        vga.writeString("Failed to read superblock\n", 15, 0);
        return;
    };

    // Load directory block
    var dir_block: [512]u8 align(@alignOf(coda.DirEntry)) = undefined;
    fs.backend.readBlocksImpl(sb.root_dir_block, dir_block[0..]) catch {
        vga.writeString("Failed to read directory\n", 15, 0);
        return;
    };

    const entry_count = sb.block_size / @sizeOf(coda.DirEntry);
    const entry_ptr: [*]coda.DirEntry = @ptrCast(&dir_block);
    const entries = entry_ptr[0..entry_count];

    // Find the file
    var found: ?*coda.DirEntry = null;
    for (entries) |*e| {
        if (e.name[0] != 0 and std.mem.eql(u8, e.name[0..filename.len], filename)) {
            found = e;
            break;
        }
    }

    if (found == null) {
        vga.writeString("File not found\n", 15, 0);
        return;
    }

    // Write the data
    fs.writeFileBlock(found.?, text) catch {
        vga.writeString("Write failed\n", 15, 0);
        return;
    };

    // Save directory block
    fs.backend.writeBlocksImpl(sb.root_dir_block, dir_block[0..]) catch {
        vga.writeString("Failed to update directory\n", 15, 0);
        return;
    };

    vga.writeString("OK\n", 15, 0);
}

fn cmd_cat(args: [][]const u8) void {
    if (args.len < 2) {
        vga.writeString("Usage: cat <file>\n", 15, 0);
        return;
    }

    const filename = args[1];

    var sb: coda.Superblock = undefined;
    fs.readSuperblock(&sb) catch return;

    var dir_block: [512]u8 align(@alignOf(coda.DirEntry)) = undefined;
    fs.backend.readBlocksImpl(sb.root_dir_block, dir_block[0..]) catch return;

    const entry_count = sb.block_size / @sizeOf(coda.DirEntry);
    const entry_ptr: [*]coda.DirEntry = @ptrCast(&dir_block);
    const entries = entry_ptr[0..entry_count];

    var found: ?*coda.DirEntry = null;
    for (entries) |*e| {
        if (e.name[0] != 0 and std.mem.eql(u8, e.name[0..filename.len], filename)) {
            found = e;
            break;
        }
    }

    if (found == null) {
        vga.writeString("File not found\n", 15, 0);
        return;
    }

    var buf: [512]u8 = undefined;
    fs.backend.readBlocksImpl(found.?.start_block, buf[0..]) catch return;

    var i: usize = 0;
    while (i < found.?.size_bytes) : (i += 1) {
        vga.putChar(buf[i], 15, 0);
    }
    vga.putChar('\n', 15, 0);
}

fn cmd_bmtest(_: [][]const u8) void {
    var buf: [16]u8 = [_]u8{0} ** 16; // 16 * 8 = 128 blocks

    // Mark some blocks used
    coda.setBlockUsed(buf[0..], 0);
    coda.setBlockUsed(buf[0..], 5);
    coda.setBlockUsed(buf[0..], 127);

    // Print a few probe results
    const probes = [_]u32{ 0, 1, 5, 6, 127 };

    for (probes) |b| {
        var num_buf: [16]u8 = undefined;
        const num_str = conv.u32ToStr(&num_buf, b);
        vga.writeRaw("block ", FG, BG);
        vga.writeRaw(num_str, FG, BG);
        vga.writeRaw(" used=", FG, BG);
        const used = coda.isBlockUsed(buf[0..], b);
        if (used) {
            vga.writeRaw("1\n", FG, BG);
        } else {
            vga.writeRaw("0\n", FG, BG);
        }
    }
}

fn cmd_freeblock(args: [][]const u8) void {
    if (args.len < 2) {
        vga.writeString("usage: freeblock <n>\n", FG, BG);
        return;
    }

    const n = conv.strToU32(args[1]) catch {
        vga.writeString("invalid number\n", FG, BG);
        return;
    };

    fs.freeBlock(n) catch {
        vga.writeString("freeBlock failed\n", FG, BG);
        return;
    };

    vga.writeString("freed block\n", FG, BG);
}

fn cmd_dumpbitmap(_: [][]const u8) void {
    var sb: coda.Superblock = undefined;
    fs.readSuperblock(&sb) catch {
        vga.writeString("failed to read superblock\n", FG, BG);
        return;
    };

    var buf: [512]u8 = undefined;
    fs.backend.readBlocksImpl(sb.bitmap_start, buf[0..]) catch {
        vga.writeString("failed to read bitmap\n", FG, BG);
        return;
    };

    // Print first 64 bits
    for (0..64) |i| {
        const byte_index = i / 8;
        const bit_index: u3 = @intCast(i % 8);
        const used = (buf[byte_index] & (@as(u8, 1) << bit_index)) != 0;

        if (used)
            vga.writeRaw("1", FG, BG)
            else
                vga.writeRaw("0", FG, BG);

        if ((i + 1) % 8 == 0)
            vga.writeRaw(" ", FG, BG);
    }

    vga.putChar('\n', FG, BG);
}

fn cmd_delete(args: [][]const u8) void {
    if (args.len < 2) {
        vga.writeString("usage: delete <filename>\n", FG, BG);
        return;
    }

    fs.deleteFile(args[1]) catch {
        vga.writeString("delete failed\n", FG, BG);
        return;
    };

    vga.writeString("deleted\n", FG, BG);
}

fn cmd_debug_setblocks(args: [][]const u8) void {
    if (args.len < 4) {
        vga.writeString("usage: dbset <file> <start> <count>\n", FG, BG);
        return;
    }

    const filename = args[1];
    const start = conv.strToU32(args[2]) catch {
        vga.writeString("invalid start block\n", FG, BG);
        return;
    };
    const count = conv.strToU32(args[3]) catch {
        vga.writeString("invalid count\n", FG, BG);
        return;
    };

    var sb: Superblock = undefined;
    fs.readSuperblock(&sb) catch return;

    var dir_block: [512]u8 align(@alignOf(DirEntry)) = undefined;
    fs.backend.readBlocksImpl(sb.root_dir_block, dir_block[0..]) catch return;

    const entry_count = sb.block_size / @sizeOf(DirEntry);
    const entries = std.mem.bytesAsSlice(DirEntry, dir_block[0 .. entry_count * @sizeOf(DirEntry)]);

    for (entries) |*e| {
        if (std.mem.eql(u8, entryNameSlice(e), filename)) {
            e.start_block = start;
            e.block_count = count;

            fs.backend.writeBlocksImpl(sb.root_dir_block, dir_block[0..]) catch return;
            vga.writeString("debug: updated entry\n", FG, BG);
            return;
        }
    }

    vga.writeString("debug: file not found\n", FG, BG);
}
fn cmd_testblocks(args: [][]const u8) void {
    if (args.len < 3) {
        vga.writeString("usage: testblocks <size> <write>\n", FG, BG);
        return;
    }

    const size = conv.strToU32(args[1]) catch return;
    const write = conv.strToU32(args[2]) catch return;

    const needed = coda.blocksNeeded(size, write, 512);
    const extra = coda.additionalBlocksNeeded(1, needed);

    var buf: [16]u8 = undefined;

    vga.writeString("blocks needed: ", FG, BG);
    vga.writeRaw(conv.u32ToStr(&buf, needed), FG, BG);
    vga.putChar('\n', FG, BG);

    vga.writeString("extra blocks: ", FG, BG);
    vga.writeRaw(conv.u32ToStr(&buf, extra), FG, BG);
    vga.putChar('\n', FG, BG);
}
