// src/kernel/shell.zig
//
// Simple line‑oriented shell for Cadenza OS.
// - No dynamic allocation beyond a provided allocator
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
const vitals = @import("vitals.zig");
const conductor = @import("conductor.zig");
const syscall = @import("syscall.zig");


const DirEntry = coda_file.DirEntry;
const Directory = coda_file.Directory;

const FG = 15;
const BG = 0;

// -----------------------------------------------------------------------------
//  GLOBAL SHELL STATE
// -----------------------------------------------------------------------------

var parse_tokens: [conf.MAX_ARGS][]const u8 = undefined;

var g_fs: *CodaFs = undefined;
var g_allocator: std.mem.Allocator = undefined;

var g_cwd_lba: u64 = 0;
var g_cwd_blocks: u32 = 0;
var g_cwd_name: [32]u8 = undefined;
var g_cwd_name_len: usize = 1; // Start with "/"

var last_latency: u64 = 0;


var last_command: conf.CommandID = .UNKNOWN;

// -----------------------------------------------------------------------------
//  COMMAND REGISTRATION
// -----------------------------------------------------------------------------

const Command = struct {
    name: []const u8,
    desc: []const u8,
    func: *const fn([][]const u8) void,
    id: conf.CommandID = .UNKNOWN,
    needs_arg: bool = false,
};

const commands = [_]Command{
    // Utility commands
    .{ .name = "help",     .desc = "Show this help message",              .func = cmd_help, .id = .UNKNOWN },
    .{ .name = "keys",     .desc = "Show key and control functions help", .func = cmd_keys, .id = .UNKNOWN },
    .{ .name = "clear",    .desc = "Clear the screen",                    .func = cmd_clear, .id = .UNKNOWN },
    .{ .name = "echo",     .desc = "Print arguments",                     .func = cmd_echo, .id = .UNKNOWN },
    .{ .name = "history",  .desc = "Show command history",                .func = cmd_history, .id = .UNKNOWN },

    // System commands
    .{ .name = "shutdown", .desc = "Power off the machine",               .func = cmd_shutdown, .id = .UNKNOWN },
    .{ .name = "reboot",   .desc = "Reboot the machine",                  .func = cmd_reboot, .id = .UNKNOWN },
    .{ .name = "vitals",   .desc = "Display vitals",                      .func = cmd_vitals,  .id = .VITALS },
    .{ .name = "version",  .desc = "Display system version information",  .func = cmd_version, .id = .VERSION },

    // Filesystem / Composer‑tracked commands
    .{ .name = "ls",       .desc = "List root directory",                 .func = cmd_ls,     .id = .LS },
    .{ .name = "touch",    .desc = "Create a file",                       .func = cmd_touch,  .id = .TOUCH,  .needs_arg = true },
    .{ .name = "edit",     .desc = "Write data into file",                .func = cmd_edit,   .id = .EDIT,   .needs_arg = true },
    .{ .name = "del",      .desc = "Delete a file",                       .func = cmd_del,    .id = .DEL },
    .{ .name = "stat",     .desc = "Read file details",                   .func = cmd_stat,   .id = .STAT,   .needs_arg = true },
    .{ .name = "cat",      .desc = "Print contents of file",              .func = cmd_cat,    .id = .CAT,    .needs_arg = true },
    .{ .name = "rename",   .desc = "Rename a file",                       .func = cmd_rename, .id = .RENAME },
    .{ .name = "mkdir",    .desc = "Create a directory",                  .func = cmd_mkdir,  .id = .MKDIR,  .needs_arg = true },
    .{ .name = "cd",       .desc = "Navigate to a folder",                .func = cmd_cd,     .id = .CD,     .needs_arg = true },
    .{ .name = "mv",       .desc = "Move a file",                         .func = cmd_mv,     .id = .MOVE },

    //The Conductor
    // Policy  control
    .{ .name = "policy",   .desc = "View/set system policy",              .func = cmd_policy, .id = .POLICY },
};

// -----------------------------------------------------------------------------
//  ARGUMENT PARSING
// -----------------------------------------------------------------------------

fn parseArgs(line: []const u8) [][]const u8 {
    var count: usize = 0;
    var i: usize = 0;

    while (i < line.len) {
        // Skip spaces
        while (i < line.len and line[i] == ' ') : (i += 1) {}
        if (i >= line.len) break;

        if (line[i] == '"') {
            // Quoted token
            i += 1;
            const start = i;

            while (i < line.len and line[i] != '"') : (i += 1) {}
            parse_tokens[count] = line[start..i];

            if (i < line.len and line[i] == '"') i += 1;
        } else {
            // Normal token
            const start = i;
            while (i < line.len and line[i] != ' ') : (i += 1) {}
            parse_tokens[count] = line[start..i];
        }

        count += 1;
        if (count >= parse_tokens.len) break;
    }

    return parse_tokens[0..count];
}

fn getCmdId(name: []const u8) conf.CommandID {
    for (commands) |c| {
        if (mem.eqlNoSimd(u8, c.name, name)) return c.id;
    }
    return .UNKNOWN;
}

// -----------------------------------------------------------------------------
//  PUBLIC ENTRY POINT
// -----------------------------------------------------------------------------

pub fn run(fs: *CodaFs, allocator: std.mem.Allocator) void {
    g_fs = fs;
    g_allocator = allocator;

    // --- CONDUCTOR INITIALIZATION ---
    // Link the Conductor to the live policy now that g_fs is set
    conductor.init(&g_fs.superblock.policy);


    g_cwd_lba = fs.superblock.root_dir_extent_start;
    g_cwd_blocks = @intCast(fs.superblock.root_dir_extent_blocks);

    // Initialize the name to root
    g_cwd_name[0] = '/';
    g_cwd_name_len = 1;

    // Load Composer and plug predictor into terminal
    loadComposer();
    term.setPredictor(shellPredictor);

    last_command = .UNKNOWN;

    while (true) {

        var prompt_buf: [64]u8 = undefined;
        const current_dir = g_cwd_name[0..g_cwd_name_len];
        const prompt = std.fmt.bufPrint(&prompt_buf, "Cadenza {s}> ", .{current_dir}) catch "Cadenza> ";

        vga.writeString(prompt, 3, 0);
        vga.updateCursorHardware();

        term.startNewLine();
        term.refresh();

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

    // --- CONDUCTOR: LISTEN ---
    // Analyze disk vitals before proceeding

    const cmd = tokens[0];
    const current_cmd_id = getCmdId(cmd);
    var found = false;

    // 1. Find and run the command
    for (commands) |c| {
        if (mem.eqlNoSimd(u8, c.name, cmd)) {
            c.func(tokens);
            found = true;
            break;
        }
    }

    // 2. Update Composer (The Learning Step)
    // Inside shell.zig -> execute()
    if (found and current_cmd_id != .UNKNOWN) {

        // 1. Record the habit via the Gateway
        _ = syscall.call(.RECORD_HABIT, @intFromEnum(last_command), @intFromEnum(current_cmd_id));

        // 2. Check Tempo via the Gateway
        const current_tempo = syscall.call(.GET_TEMPO, 0, 0);
        if (current_tempo == @intFromEnum(conductor.ConductorState.Optimal)) {
            saveComposer() catch {};
        }

        last_command = current_cmd_id;
    }

    // 3. Dev-Mode Telemetry
    // This gives the developer a raw look at cycles if things feel slow.
    if (g_fs.superblock.policy == .Dev) {
        if (vitals.current_vitals.last_read_latency > 10_000_000) {
            vga.writeString("!! Conductor: Latency Spike Detected !!\n", 14, 0);
        }
    }
}

// -----------------------------------------------------------------------------
//  UTILITY COMMANDS
// -----------------------------------------------------------------------------

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
}

fn cmd_keys(_: [][]const u8) void {
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

// Not registered, but kept as a simple test command
fn cmd_test(_: [][]const u8) void {
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        vga.putChar('#', FG, BG);
    }
    vga.putChar('\n', FG, BG);
}

// -----------------------------------------------------------------------------
//  SYSTEM COMMANDS
// -----------------------------------------------------------------------------

fn cmd_shutdown(_: [][]const u8) void {
    vga.writeString("Shutting down...\n", FG, BG);
    system.shutdown();
}

fn cmd_reboot(_: [][]const u8) void {
    vga.writeString("Rebooting...\n", FG, BG);
    system.reboot();
}

fn cmd_vitals(tokens: [][]const u8) void {
    _ = tokens;

    var buf: [128]u8 = undefined;

    const line1 = std.fmt.bufPrint(&buf, "Total Disk Cycles: {d}\n", .{vitals.current_vitals.disk_cycles}) catch "Error\n";
    vga.writeString(line1, 15, 0);

    const line2 = std.fmt.bufPrint(&buf, "Last Read Latency: {d} cycles\n", .{vitals.current_vitals.last_read_latency}) catch "Error\n";
    vga.writeString(line2, 16, 0);
}

fn cmd_version(args: [][]const u8) void {
    _ = args;
    vga.writeString("Cadenza OS - Version 0.1.0 (Dev Build)\n", 11, 0);
    vga.writeString("Kernel: Zig 0.16-dev\n", 7, 0);
    vga.writeString("Predictive Shell: Phase 1 Context-Aware\n", 10, 0);
}

// -----------------------------------------------------------------------------
//  FILESYSTEM COMMANDS
// -----------------------------------------------------------------------------

fn cmd_ls(args: [][]const u8) void {
    var target_lba = g_cwd_lba;
    var target_blocks = g_cwd_blocks;

    if (args.len > 1) {
        const result = g_fs.resolvePath(g_allocator, g_cwd_lba, args[1]) catch |err| {
            vga.writeString("Error: ", 12, 0);
            vga.writeString(@errorName(err), 12, 0);
            vga.writeString("\n", 12, 0);
            return;
        };

        target_lba = result.lba;
        target_blocks = @intCast(result.blocks);

        if (!result.is_directory) {
            vga.writeString("Error: Path is a file, not a directory.\n", 12, 0);
            return;
        }
    }

    const entries = g_fs.listDir(g_allocator, target_lba, target_blocks) catch |err| {
        vga.writeString("ls failed: ", 12, 0);
        vga.writeString(@errorName(err), 12, 0);
        vga.putChar('\n', 15, 0);
        return;
    };
    defer g_allocator.free(entries);

    if (entries.len == 0) {
        vga.writeString("(empty)\n", 7, 0);
        return;
    }

    for (entries) |entry| {
        const meta = g_fs.readFileMeta(g_allocator, entry.meta_extent.start_block) catch continue;

        if (meta.file_type == .Directory) {
            vga.writeString("[DIR]  ", 11, 0);
        } else {
            vga.writeString("[FILE] ", 15, 0);
        }

        const name = entry.name[0..entry.name_len];
        const color: u8 = if (meta.file_type == .Directory) 11 else 15;

        for (name) |c| {
            vga.putChar(c, color, 0);
        }

        if (meta.file_type == .Directory) {
            vga.putChar('/', 11, 0);
        }

        vga.putChar('\n', 15, 0);
    }
}

fn cmd_touch(args: [][]const u8) void {
    if (args.len < 2) {
        vga.writeString("Usage: touch <path>\n", 0x07, 0);
        return;
    }

    const full_path = args[1];
    const last_slash_idx = std.mem.lastIndexOfScalar(u8, full_path, '/');

    var parent_lba: u64 = g_cwd_lba;
    var parent_blocks: u64 = g_cwd_blocks;
    var filename: []const u8 = full_path;

    if (last_slash_idx) |idx| {
        const dir_part = if (idx == 0) "/" else full_path[0..idx];
        filename = full_path[idx + 1 ..];

        const result = g_fs.resolvePath(g_allocator, g_cwd_lba, dir_part) catch {
            vga.writeString("Error: Parent directory not found.\n", 0x0C, 0);
            return;
        };
        parent_lba = result.lba;
        parent_blocks = @intCast(result.blocks);
    }

    g_fs.createFile(g_allocator, parent_lba, parent_blocks, filename) catch |err| {
        vga.writeString("Failed to create file: ", 0x0C, 0);
        vga.writeString(@errorName(err), 0x0C, 0);
        vga.writeString("\n", 0x07, 0);
    };
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

    const meta = g_fs.readFileMeta(g_allocator, lba.meta_extent.start_block) catch {
        vga.writeString("Failed to read metadata\n", FG, BG);
        return;
    };

    var name_line: [64]u8 = undefined;
    const name_full = std.fmt.bufPrint(&name_line, "File: {s}", .{filename}) catch "File: [name error]";
    vga.writeString(name_full, FG, BG);

    if (meta.file_type == .File) {
        vga.writeString("Type: Regular File", FG, BG);
    } else {
        vga.writeString("Type: Directory", FG, BG);
    }

    var size_num_buf: [16]u8 = undefined;
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

fn cmd_cat(args: [][]const u8) void {
    if (args.len < 2) {
        vga.writeString("Usage: cat <filename>\n", FG, BG);
        return;
    }

    const filename = args[1];

    const entry = g_fs.findFile(g_allocator, g_cwd_lba, filename) catch {
        vga.writeString("Error: File not found\n", FG, BG);
        return;
    };

    const meta = g_fs.readFileMeta(g_allocator, entry.meta_extent.start_block) catch {
        vga.writeString("Error: Could not read metadata\n", FG, BG);
        return;
    };

    if (meta.file_type == .Directory) {
        vga.writeString("Error: Cannot 'cat' a directory.\n", FG, BG);
        return;
    }

    if (meta.size_bytes == 0) {
        vga.writeString("(File is empty)\n", FG, BG);
        return;
    }

    const buf = g_allocator.alloc(u8, 512) catch return;
    defer g_allocator.free(buf);

    var bytes_remaining = meta.size_bytes;

    for (meta.extents[0..meta.extent_count]) |extent| {
        if (bytes_remaining == 0) break;

        var block_idx: u64 = 0;
        while (block_idx < extent.block_count and bytes_remaining > 0) : (block_idx += 1) {
            const current_lba = extent.start_block + block_idx;

            g_fs.device.readBlocks(g_fs.device.ctx, current_lba, buf) catch {
                vga.writeString("\nError: Disk read failure\n", FG, BG);
                return;
            };

            const chunk_size = if (bytes_remaining > 512) @as(usize, 512) else @as(usize, @intCast(bytes_remaining));

            vga.writeRaw(buf[0..chunk_size], FG, BG);

            bytes_remaining -= chunk_size;
        }
    }

    vga.writeString("\n", FG, BG);
}

fn cmd_del(args: [][]const u8) void {
    if (args.len < 2) {
        vga.writeString("Usage: del <filename>\n", FG, BG);
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

    const entries = g_fs.listDir(g_allocator, g_cwd_lba, g_cwd_blocks) catch {
        vga.writeString("Error: Could not read directory.\n", 12, 0);
        return;
    };
    defer g_allocator.free(entries);

    var found = false;
    for (entries) |*e| {
        if (std.mem.eql(u8, e.name[0..e.name_len], old_name)) {
            if (new_name.len > 64) {
                vga.writeString("Error: New name too long.\n", 12, 0);
                return;
            }

            @memset(e.name[0..], 0);
            @memcpy(e.name[0..new_name.len], new_name);
            e.name_len = @intCast(new_name.len);
            found = true;
            break;
        }
    }

    if (!found) {
        vga.writeString("Error: File not found.\n", 12, 0);
        return;
    }

    g_fs.saveDirectoryEntries(g_allocator, g_cwd_lba, entries) catch {
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
    const path_str = args[1];

    const result = g_fs.resolvePath(g_allocator, g_cwd_lba, path_str) catch |err| {
        if (err == error.PathNotFound) {
            vga.writeString("Error: Directory not found.\n", 12, 0);
        } else {
            vga.writeString("Error: Invalid path.\n", 12, 0);
        }
        return;
    };

    if (result.is_directory) {
        g_cwd_lba = result.lba;
        g_cwd_blocks = @intCast(result.blocks);

        if (path_str[0] == '/') {
            const copy_len = if (path_str.len > 30) 30 else path_str.len;
            @memcpy(g_cwd_name[0..copy_len], path_str[0..copy_len]);
            g_cwd_name_len = copy_len;
        } else if (std.mem.eql(u8, path_str, ".") or std.mem.eql(u8, path_str, "..")) {
            // no change to prompt string
        } else {
            if (g_cwd_name_len == 1 and g_cwd_name[0] == '/') {
                const copy_len = if (path_str.len > 29) 29 else path_str.len;
                @memcpy(g_cwd_name[1 .. 1 + copy_len], path_str[0..copy_len]);
                g_cwd_name_len = 1 + copy_len;
            } else {
                if (g_cwd_name_len + path_str.len + 1 < 31) {
                    g_cwd_name[g_cwd_name_len] = '/';
                    @memcpy(g_cwd_name[g_cwd_name_len + 1 .. g_cwd_name_len + 1 + path_str.len], path_str);
                    g_cwd_name_len += (1 + path_str.len);
                }
            }
        }

        vga.writeString("Changed directory.\n", 10, 0);
    } else {
        vga.writeString("Error: Target is a file, not a directory.\n", 12, 0);
    }
}

fn cmd_mv(args: [][]const u8) void {
    if (args.len < 3) {
        vga.writeString("Usage: mv <source_path> <dest_dir>\n", 15, 0);
        return;
    }

    const src_path = args[1];
    const dest_path = args[2];

    var src_dir_path: []const u8 = ".";
    var src_filename: []const u8 = src_path;

    if (std.mem.lastIndexOfScalar(u8, src_path, '/')) |idx| {
        src_dir_path = src_path[0..idx];
        src_filename = src_path[idx + 1 ..];
        if (src_dir_path.len == 0) src_dir_path = "/";
    }

    const src_parent = g_fs.resolvePath(g_allocator, g_cwd_lba, src_dir_path) catch {
        vga.writeString("Error: Source directory not found.\n", 12, 0);
        return;
    };

    const entry_to_move = g_fs.findAndRemoveEntry(
        g_allocator,
        src_parent.lba,
        @intCast(src_parent.blocks),
                                                  src_filename,
    ) catch |err| {
        vga.writeString("Error: Could not find source file: ", 12, 0);
        vga.writeString(@errorName(err), 12, 0);
        vga.putChar('\n', 15, 0);
        return;
    };

    const dest_resolve = g_fs.resolvePath(g_allocator, g_cwd_lba, dest_path) catch |err| {
        _ = g_fs.insertEntry(g_allocator, src_parent.lba, entry_to_move) catch {};
        vga.writeString("Error: Dest resolution failed: ", 12, 0);
        vga.writeString(@errorName(err), 12, 0);
        vga.putChar('\n', 15, 0);
        return;
    };

    vga.writeString("DEBUG: is_dir = ", 14, 0);
    if (dest_resolve.is_directory) {
        vga.writeString("TRUE\n", 10, 0);
    } else {
        vga.writeString("FALSE\n", 12, 0);
    }

    if (dest_resolve.is_directory) {
        g_fs.insertEntry(
            g_allocator,
            dest_resolve.lba,
            entry_to_move,
        ) catch |err| {
            _ = g_fs.insertEntry(g_allocator, src_parent.lba, entry_to_move) catch {};
            vga.writeString("Insert failed: ", 12, 0);
            vga.writeString(@errorName(err), 12, 0);
            vga.putChar('\n', 15, 0);
            return;
        };
        vga.writeString("Move successful!\n", 10, 0);
    } else {
        _ = g_fs.insertEntry(g_allocator, src_parent.lba, entry_to_move) catch {};
        vga.writeString("Error: Target is a file.\n", 12, 0);
    }
}

fn cmd_edit(args: [][]const u8) void {
    if (args.len < 3) {
        vga.writeString("Usage: edit <filename> <text>\n", 15, 0);
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

    var meta_lba: u64 = 0;

    if (g_fs.findFile(g_allocator, g_cwd_lba, filename)) |entry| {
        meta_lba = entry.meta_extent.start_block;
    } else |_| {
        g_fs.createFile(g_allocator, g_cwd_lba, g_cwd_blocks, filename) catch {
            vga.writeString("Error: Could not create file\n", 12, 0);
            return;
        };
        const new_entry = g_fs.findFile(g_allocator, g_cwd_lba, filename) catch {
            vga.writeString("Error: File created but not found\n", 12, 0);
            return;
        };
        meta_lba = new_entry.meta_extent.start_block;
    }

    var meta = g_fs.readFileMeta(g_allocator, meta_lba) catch {
        vga.writeString("Error: Could not read metadata\n", 12, 0);
        return;
    };

    const old_size = meta.size_bytes;
    const total_new_size = old_size + final_text.len;
    const total_blocks_needed = (total_new_size + 511) / 512;

    while (meta.extent_count < total_blocks_needed) {
        g_fs.addBlockToFile(g_allocator, &meta) catch |err| {
            if (err == error.FileAtMaximumSize) {
                vga.writeString("Warning: File capped at 4KB.\n", 14, 0);
                break;
            }
            vga.writeString("Error: Disk full.\n", 12, 0);
            return;
        };
    }

    const block_buf = g_allocator.alloc(u8, 512) catch return;
    defer g_allocator.free(block_buf);

    var bytes_to_append = final_text.len;
    var write_offset: usize = old_size;

    while (bytes_to_append > 0) {
        const block_idx = write_offset / 512;
        const offset_in_block = write_offset % 512;

        const target_lba = getLbaForBlock(meta, block_idx);

        g_fs.device.readBlocks(g_fs.device.ctx, target_lba, block_buf) catch {
            vga.writeString("Error: Read failed\n", 12, 0);
            return;
        };

        const space_in_block = 512 - offset_in_block;
        const copy_size = if (bytes_to_append > space_in_block) space_in_block else bytes_to_append;

        const source_start = final_text.len - bytes_to_append;
        @memcpy(
            block_buf[offset_in_block .. offset_in_block + copy_size],
            final_text[source_start .. source_start + copy_size],
        );

        g_fs.device.writeBlocks(g_fs.device.ctx, target_lba, block_buf) catch {
            vga.writeString("Error: Write failed\n", 12, 0);
            return;
        };

        write_offset += copy_size;
        bytes_to_append -= copy_size;
    }

    meta.size_bytes = @intCast(total_new_size);
    g_fs.writeBlockStruct(meta_lba, &meta, @sizeOf(coda_file.FileMeta)) catch {
        vga.writeString("Error: Metadata sync failed\n", 12, 0);
        return;
    };

    vga.writeString("Success: Data appended to Coda FS.\n", 10, 0);
}

// -----------------------------------------------------------------------------
//  POLICY / COMPOSER COMMANDS
// -----------------------------------------------------------------------------

fn cmd_policy(args: [][]const u8) void {
    if (args.len < 2) {
        vga.writeString("Current Policy: ", 15, 0);
        switch (g_fs.superblock.policy) {
            .Admin     => vga.writeString("Admin\n", 14, 0),
            .Dev       => vga.writeString("Dev\n", 10, 0),
            .Gaming    => vga.writeString("Gaming\n", 13, 0),
            .AI_Guided => vga.writeString("AI_Guided\n", 11, 0),
        }
        return;
    }

    const new_policy = args[1];

    if (std.mem.eql(u8, new_policy, "admin")) {
        g_fs.superblock.policy = .Admin;
        vga.writeString("Policy switched to Admin\n", 14, 0);
    } else if (std.mem.eql(u8, new_policy, "dev")) {
        g_fs.superblock.policy = .Dev;
        vga.writeString("Policy switched to Dev\n", 10, 0);
    } else if (std.mem.eql(u8, new_policy, "gaming")) {
        g_fs.superblock.policy = .Gaming;
        vga.writeString("Policy switched to Gaming\n", 13, 0);
    } else if (std.mem.eql(u8, new_policy, "ai")) {
        g_fs.superblock.policy = .AI_Guided;
        vga.writeString("Policy switched to AI_Guided\n", 11, 0);
    } else {
        vga.writeString("Unknown policy. Use: admin, dev, gaming, or ai\n", 12, 0);
        return;
    }

    saveComposer() catch {};
}

// -----------------------------------------------------------------------------
//  COMPOSER / PREDICTION HELPERS
// -----------------------------------------------------------------------------

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

fn showSuggestion(tokens: [][]const u8) void {
    if (tokens.len == 0) return;
    const cmd = tokens[0];

    var buffer: [80]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    const suggestion =
    if (std.mem.eql(u8, cmd, "mkdir") and tokens.len > 1)
        std.fmt.allocPrint(allocator, " [Heuristic: try 'cd {s}']\n", .{tokens[1]}) catch " [Heuristic: try cd]\n"
        else if (std.mem.eql(u8, cmd, "ls"))
            " [Heuristic: use 'stat' for latency]\n"
            else
                " [Heuristic: system optimal]\n";

    vga.writeString(suggestion, 10, 0);
}

pub fn predictNextCommand() []const u8 {
    const prev_idx = @intFromEnum(last_command);
    var best_weight: u16 = 0;
    var best_id_val: u8 = 0;

    for (conductor.transition_table[prev_idx], 0..) |weight, i| {
        if (weight > best_weight) {
            best_weight = weight;
            best_id_val = @intCast(i);
        }
    }

    if (best_weight == 0) return "help";

    const best_id = @as(conf.CommandID, @enumFromInt(best_id_val));

    for (commands) |c| {
        if (c.id == best_id and c.id != .UNKNOWN) {
            return c.name;
        }
    }

    return "help";
}

// Predictor plugged into terminal.zig
fn shellPredictor(input: []const u8) []const u8 {
    const table_size = conductor.transition_table.len;
    const prev_idx = @intFromEnum(last_command);
    if (prev_idx >= table_size) return "";

    // 1. EMPTY INPUT CASE (The "Proactive" suggestion)
    if (input.len == 0) {
        var top_score: u16 = 0;
        var top_idx: usize = 0;

        // Find the most likely transition in the Markov table
        for (conductor.transition_table[prev_idx], 0..) |score, i| {
            if (score > top_score) {
                top_score = score;
                top_idx = i;
            }
        }

        // Only suggest if the habit is established (e.g., 5+ times)
        if (top_score > 5) {
            for (commands) |c| {
                if (@intFromEnum(c.id) == top_idx) {
                    return c.name;
                }
            }
        }
        return "";
    }

    // 2. TYPING CASE (The "Ghost Text" suggestion)
    const is_admin = (g_fs.superblock.policy == .Admin);
    var best_score: i32 = -1;
    var best_match: ?[]const u8 = null;

    for (commands) |c| {
        // PERF: Skip immediately if the first letter doesn't match
        if (c.name.len <= input.len or c.name[0] != input[0]) continue;

        if (std.mem.startsWith(u8, c.name, input)) {
            const tidx = @intFromEnum(c.id);
            var score: i32 = 0;

            if (tidx < table_size) {
                score = @intCast(conductor.transition_table[prev_idx][tidx]);
            }

            // Multiply habits to make them beat alphabetical order
            var effective_score = score * 10;

            // Fast Admin Boost
            if (is_admin) {
                if (c.name[0] == 'v' or c.name[0] == 'p') {
                    if (std.mem.eql(u8, c.name, "vitals") or std.mem.eql(u8, c.name, "policy")) {
                        effective_score += 1000;
                    }
                }
            }

            if (effective_score > best_score) {
                best_score = effective_score;
                best_match = c.name;
            }
        }
    }

    if (best_match) |bm| return bm[input.len..];
    return "";
}

fn getHighestTransition(prev: conf.CommandID) conf.CommandID {
    const prev_idx = @intFromEnum(prev);
    var best_id: conf.CommandID = .UNKNOWN;
    var max_val: u16 = 0;

    const threshold: u16 = 2;

    for (conductor.transition_table[prev_idx], 0..) |weight, i| {
        if (weight > max_val and weight >= threshold) {
            max_val = weight;
            best_id = @enumFromInt(i);
        }
    }

    return best_id;
}

fn getNameFromId(id: conf.CommandID) ?[]const u8 {
    for (commands) |cmd| {
        if (cmd.id == id) return cmd.name;
    }
    return null;
}

fn saveComposer() !void {
    const root_lba = g_fs.superblock.root_dir_extent_start;

    const sys_entry = g_fs.findFile(g_allocator, root_lba, "sys") catch |err| blk: {
        if (err == error.FileNotFound) {
            try g_fs.createEntry(g_allocator, root_lba, 1, "sys", .Directory);
            break :blk try g_fs.findFile(g_allocator, root_lba, "sys");
        }
        return err;
    };

    const sys_meta = try g_fs.readFileMeta(g_allocator, sys_entry.meta_extent.start_block);
    if (sys_meta.file_type != .Directory) return error.NotADirectory;

    const sys_meta_lba = sys_entry.meta_extent.start_block;

    const composer_entry = g_fs.findFile(g_allocator, sys_meta_lba, "composer.dat") catch |err| blk: {
        if (err == error.FileNotFound) {
            try g_fs.createFile(g_allocator, sys_meta_lba, 4, "composer.dat");
            break :blk try g_fs.findFile(g_allocator, sys_meta_lba, "composer.dat");
        }
        return err;
    };

    var composer_meta = try g_fs.readFileMeta(g_allocator, composer_entry.meta_extent.start_block);
    const data_lba = composer_meta.extents[0].start_block;

    const bytes = std.mem.sliceAsBytes(&conductor.transition_table);
    try g_fs.device.writeBlocks(g_fs.device.ctx, data_lba, bytes);

    composer_meta.size_bytes = bytes.len;
    composer_meta.extents[0].block_count = 1;

    try g_fs.writeBlockStruct(
        composer_entry.meta_extent.start_block,
        &composer_meta,
        @sizeOf(@TypeOf(composer_meta)),
    );
}

fn loadComposer() void {
    const path_res = g_fs.resolvePath(
        g_allocator,
        g_fs.superblock.root_dir_extent_start,
        "/sys/composer.dat",
    ) catch return;

    const meta = g_fs.readFileMeta(g_allocator, path_res.lba) catch return;
    const data_lba = meta.extents[0].start_block;

    const bytes = std.mem.sliceAsBytes(&conductor.transition_table);

    g_fs.device.readBlocks(g_fs.device.ctx, data_lba, bytes) catch return;
}

/// Increases the probability weight between two commands.
fn rewardTransition(prev: conf.CommandID, curr: conf.CommandID) void {
    const p = @intFromEnum(prev);
    const c = @intFromEnum(curr);

    if (conductor.transition_table[p][c] < 255) {
        conductor.transition_table[p][c] += 1;
    }
}
