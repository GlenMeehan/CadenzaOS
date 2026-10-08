// src/kernel/input/key_event.zig
//
// Keyboard event types used by the input subsystem.
//
// A KeyEvent represents a decoded key action delivered by a keyboard
// driver. Events are normalised into one of two categories:
//
//   • char    — printable ASCII character data
//   • special — non-printable navigation or control key
//
// This abstraction allows higher layers (shell, editor, UI, etc.) to
// consume keyboard input without depending on device-specific scancodes.

/// A decoded keyboard event.
pub const KeyEvent = union(enum) {
    /// Printable ASCII character.
    char: u8,

    /// Non-printable key with special meaning.
    special: SpecialKey,
};

/// Supported non-printable keyboard keys.
///
/// These values represent logical keys rather than hardware scancodes.
pub const SpecialKey = enum {
    Left,
    Right,
    Up,
    Down,
    Home,
    End,
    Escape,
    Tab,
    Delete,
};
