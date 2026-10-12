// src/kernel/security.zig
//
// Simple pattern-based traffic inspection helpers.
//
// This module performs lightweight content checks against known
// suspicious byte sequences. It is intended as a basic filtering
// mechanism rather than a complete intrusion-detection system.
//

/// Known patterns associated with potentially malicious input.
///
/// These signatures are simple examples and should not be considered
/// comprehensive protection against real-world attacks.
const MaliciousPatterns = [_][]const u8{
    "\x90\x90\x90", // Common NOP-sled sequence used in exploit payloads
    "../../",       // Directory traversal attempt
};

/// Inspect input data for known blocked patterns.
///
/// Returns:
///   • true  - no known malicious patterns detected
///   • false - suspicious content detected
///
/// Inspection is performed using a simple signature-matching approach.
pub fn inspectTraffic(data: []const u8) bool {
    for (MaliciousPatterns) |pattern| {

        // Reject the input immediately if a known signature is found.
        if (std.mem.indexOf(u8, data, pattern) != null) {
            return false;
        }
    }

    return true;
}
