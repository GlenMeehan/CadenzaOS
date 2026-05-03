// src/kernel/security.zig

// Pre-learned "Bad" patterns (e.g., specific packet sequences or command strings)
const MaliciousPatterns = [_][]const u8{
    "\x90\x90\x90", // Example: NOP sled (common in buffer overflows)
    "../../",       // Example: Directory traversal attempt
};

pub fn inspectTraffic(data: []const u8) bool {
    for (MaliciousPatterns) |pattern| {
        if (std.mem.indexOf(u8, data, pattern) != null) return false; // Block it!
    }
    return true;
}
