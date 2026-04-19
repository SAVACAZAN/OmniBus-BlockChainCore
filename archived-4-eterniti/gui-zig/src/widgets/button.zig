const rl = @import("../raylib.zig");
const theme = @import("../theme.zig");

pub const ButtonStyle = enum {
    primary,
    secondary,
    ghost,
    danger,
};

pub const ButtonResult = struct {
    clicked: bool,
    hovered: bool,
};

pub fn draw(x: c_int, y: c_int, w: c_int, h: c_int, text: [*:0]const u8, style: ButtonStyle, font_size: c_int) ButtonResult {
    const mx = rl.getMouseX();
    const my = rl.getMouseY();
    const hovered = mx >= x and mx < x + w and my >= y and my < y + h;
    const pressing = hovered and rl.isMouseButtonDown(rl.MOUSE_LEFT);
    const clicked = hovered and rl.isMouseButtonReleased(rl.MOUSE_LEFT);

    const bg_color = switch (style) {
        .primary => if (pressing) theme.accent_press else if (hovered) theme.accent_hover else theme.accent,
        .secondary => if (pressing) rl.Color{ .r = 0x2a, .g = 0x2d, .b = 0x54, .a = 0xff } else if (hovered) rl.Color{ .r = 0x3a, .g = 0x3d, .b = 0x54, .a = 0xff } else rl.Color{ .r = 0x2a, .g = 0x2d, .b = 0x44, .a = 0xff },
        .ghost => if (pressing) rl.Color{ .r = 0x2a, .g = 0x2d, .b = 0x44, .a = 0xff } else if (hovered) rl.Color{ .r = 0x22, .g = 0x25, .b = 0x3a, .a = 0xff } else rl.Color{ .r = 0x1a, .g = 0x1d, .b = 0x2e, .a = 0xff },
        .danger => if (pressing) rl.Color{ .r = 0xc9, .g = 0x3a, .b = 0x3a, .a = 0xff } else if (hovered) rl.Color{ .r = 0xe9, .g = 0x5a, .b = 0x5a, .a = 0xff } else theme.danger,
    };

    const text_color = switch (style) {
        .primary, .danger => rl.Color{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff },
        .secondary => theme.text_primary,
        .ghost => if (hovered) theme.text_primary else theme.text_secondary,
    };

    const hf: f32 = @floatFromInt(h);
    const rect = rl.Rectangle{ .x = @floatFromInt(x), .y = @floatFromInt(y), .width = @floatFromInt(w), .height = hf };
    rl.drawRectangleRounded(rect, theme.button_rounding / hf, 6, bg_color);

    if (style == .secondary) {
        rl.drawRectangleRoundedLines(rect, theme.button_rounding / hf, 6, theme.accent);
    } else if (style == .ghost) {
        rl.drawRectangleRoundedLines(rect, theme.button_rounding / hf, 6, rl.Color{ .r = 0x3a, .g = 0x3d, .b = 0x54, .a = 0xff });
    }

    // Center text
    const text_w = rl.measureText(text, font_size);
    rl.drawText(text, x + @divTrunc(w - text_w, 2), y + @divTrunc(h - font_size, 2), font_size, text_color);

    return .{ .clicked = clicked, .hovered = hovered };
}

pub fn drawWide(x: c_int, y: c_int, w: c_int, h: c_int, text: [*:0]const u8, style: ButtonStyle, font_size: c_int) ButtonResult {
    const mx = rl.getMouseX();
    const my = rl.getMouseY();
    const hovered = mx >= x and mx < x + w and my >= y and my < y + h;
    const pressing = hovered and rl.isMouseButtonDown(rl.MOUSE_LEFT);
    const clicked = hovered and rl.isMouseButtonReleased(rl.MOUSE_LEFT);

    const bg_color = switch (style) {
        .primary => if (pressing) theme.accent_press else if (hovered) theme.accent_hover else theme.accent,
        .secondary => if (pressing) rl.Color{ .r = 0x2a, .g = 0x2d, .b = 0x54, .a = 0xff } else if (hovered) rl.Color{ .r = 0x3a, .g = 0x3d, .b = 0x54, .a = 0xff } else rl.Color{ .r = 0x2a, .g = 0x2d, .b = 0x44, .a = 0xff },
        .ghost => if (pressing) rl.Color{ .r = 0x2a, .g = 0x2d, .b = 0x44, .a = 0xff } else if (hovered) rl.Color{ .r = 0x22, .g = 0x25, .b = 0x3a, .a = 0xff } else rl.Color{ .r = 0x1a, .g = 0x1d, .b = 0x2e, .a = 0xff },
        .danger => if (pressing) rl.Color{ .r = 0xc9, .g = 0x3a, .b = 0x3a, .a = 0xff } else if (hovered) rl.Color{ .r = 0xe9, .g = 0x5a, .b = 0x5a, .a = 0xff } else theme.danger,
    };

    const text_color = switch (style) {
        .primary, .danger => rl.Color{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff },
        .secondary => theme.text_primary,
        .ghost => if (hovered) theme.text_primary else theme.text_secondary,
    };

    const hf: f32 = @floatFromInt(h);
    const rect = rl.Rectangle{ .x = @floatFromInt(x), .y = @floatFromInt(y), .width = @floatFromInt(w), .height = hf };
    rl.drawRectangleRounded(rect, theme.button_rounding / hf, 6, bg_color);

    if (style == .secondary) {
        rl.drawRectangleRoundedLines(rect, theme.button_rounding / hf, 6, theme.accent);
    } else if (style == .ghost) {
        rl.drawRectangleRoundedLines(rect, theme.button_rounding / hf, 6, rl.Color{ .r = 0x3a, .g = 0x3d, .b = 0x54, .a = 0xff });
    }

    // Left-aligned text
    rl.drawText(text, x + 20, y + @divTrunc(h - font_size, 2), font_size, text_color);

    return .{ .clicked = clicked, .hovered = hovered };
}
