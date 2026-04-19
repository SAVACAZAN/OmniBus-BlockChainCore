const rl = @import("raylib.zig");

// ═══════════════════════════════════════════════════════════════
//  OmniBus Dark Theme — matching Qt dark-theme.qss
// ═══════════════════════════════════════════════════════════════

pub const bg_dark = rl.Color{ .r = 0x0d, .g = 0x0f, .b = 0x1a, .a = 0xff };
pub const bg_main = rl.Color{ .r = 0x11, .g = 0x13, .b = 0x1f, .a = 0xff };
pub const bg_panel = rl.Color{ .r = 0x1a, .g = 0x1d, .b = 0x3a, .a = 0xff };
pub const bg_hover = rl.Color{ .r = 0x1d, .g = 0x20, .b = 0x40, .a = 0xff };
pub const bg_input = rl.Color{ .r = 0x0d, .g = 0x0f, .b = 0x1a, .a = 0xff };
pub const bg_card = rl.Color{ .r = 0x14, .g = 0x16, .b = 0x28, .a = 0xff };

pub const border = rl.Color{ .r = 0x2a, .g = 0x2d, .b = 0x4a, .a = 0xff };
pub const border_focus = rl.Color{ .r = 0x4a, .g = 0x90, .b = 0xd9, .a = 0xff };

pub const accent = rl.Color{ .r = 0x4a, .g = 0x90, .b = 0xd9, .a = 0xff };
pub const accent_hover = rl.Color{ .r = 0x5a, .g = 0xa0, .b = 0xe9, .a = 0xff };
pub const accent_press = rl.Color{ .r = 0x3a, .g = 0x80, .b = 0xc9, .a = 0xff };

pub const teal = rl.Color{ .r = 0x00, .g = 0xb3, .b = 0xa4, .a = 0xff };
pub const teal_bright = rl.Color{ .r = 0x00, .g = 0xff, .b = 0xcc, .a = 0xff };

pub const danger = rl.Color{ .r = 0xd9, .g = 0x4a, .b = 0x4a, .a = 0xff };
pub const success = rl.Color{ .r = 0x4a, .g = 0xd9, .b = 0x6a, .a = 0xff };
pub const warning = rl.Color{ .r = 0xf3, .g = 0xba, .b = 0x2f, .a = 0xff };

pub const text_primary = rl.Color{ .r = 0xe0, .g = 0xe0, .b = 0xf0, .a = 0xff };
pub const text_secondary = rl.Color{ .r = 0x88, .g = 0x88, .b = 0xaa, .a = 0xff };
pub const text_dim = rl.Color{ .r = 0x66, .g = 0x66, .b = 0xaa, .a = 0xff };
pub const text_muted = rl.Color{ .r = 0x55, .g = 0x55, .b = 0x66, .a = 0xff };
pub const text_version = rl.Color{ .r = 0x44, .g = 0x44, .b = 0x66, .a = 0xff };

pub const selection = rl.Color{ .r = 0x4a, .g = 0x90, .b = 0xd9, .a = 0x4c };

// Chain colors
pub const btc_orange = rl.Color{ .r = 0xf7, .g = 0x93, .b = 0x1a, .a = 0xff };
pub const eth_blue = rl.Color{ .r = 0x62, .g = 0x7e, .b = 0xea, .a = 0xff };
pub const bnb_yellow = rl.Color{ .r = 0xf3, .g = 0xba, .b = 0x2f, .a = 0xff };
pub const sol_purple = rl.Color{ .r = 0x99, .g = 0x45, .b = 0xff, .a = 0xff };
pub const ada_blue = rl.Color{ .r = 0x00, .g = 0x33, .b = 0xad, .a = 0xff };
pub const dot_pink = rl.Color{ .r = 0xe6, .g = 0x00, .b = 0x7a, .a = 0xff };
pub const purple_addr = rl.Color{ .r = 0x7b, .g = 0x61, .b = 0xff, .a = 0xff };

// Font sizes
pub const font_xs: c_int = 10;
pub const font_sm: c_int = 12;
pub const font_md: c_int = 14;
pub const font_lg: c_int = 16;
pub const font_xl: c_int = 20;
pub const font_title: c_int = 32;

// Layout
pub const card_rounding: f32 = 8.0;
pub const button_rounding: f32 = 8.0;
pub const input_rounding: f32 = 6.0;
pub const padding: c_int = 16;
pub const spacing: c_int = 12;
