// cadenza/src/kernel/logo.zig

// Set these to the exact pixel width and height of your Splash.rgb image
pub const LOGO_WIDTH: u32 = 512;
pub const LOGO_HEIGHT: u32 = 512;

/// Embeds cadenza/assets/Splash.rgb directly into the kernel binary
pub const logo_data = @embedFile("assets/Splash.rgb");
