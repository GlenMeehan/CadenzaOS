// src/kernel/logo.zig
//
// Embedded splash-screen image resources.
//
// Provides the raw RGB image data and dimensions required by the
// splash-screen renderer during kernel startup.
//

/// Width of the embedded splash image in pixels.
///
/// Must match the actual dimensions of assets/Splash.rgb.
pub const LOGO_WIDTH: u32 = 512;

/// Height of the embedded splash image in pixels.
///
/// Must match the actual dimensions of assets/Splash.rgb.
pub const LOGO_HEIGHT: u32 = 512;

/// Raw RGB image data embedded directly into the kernel binary.
///
/// The image is stored as a contiguous sequence of RGB pixels and is
/// consumed by the splash-screen rendering subsystem during boot.
pub const logo_data = @embedFile("assets/Splash.rgb");

