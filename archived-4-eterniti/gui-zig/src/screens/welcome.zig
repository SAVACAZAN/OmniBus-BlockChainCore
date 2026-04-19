const rl = @import("../raylib.zig");
const theme = @import("../theme.zig");
const btn = @import("../widgets/button.zig");

pub const WelcomeChoice = enum {
    none,
    create_wallet,
    import_wallet,
    connect_node,
};

pub fn draw(screen_w: c_int, screen_h: c_int) WelcomeChoice {
    const card_w: c_int = 520;
    const card_h: c_int = 520;
    const cx = @divTrunc(screen_w - card_w, 2);
    const cy = @divTrunc(screen_h - card_h, 2);

    // Overlay
    rl.drawRectangle(0, 0, screen_w, screen_h, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 120 });

    // Card
    const card_rect = rl.Rectangle{
        .x = @floatFromInt(cx),
        .y = @floatFromInt(cy),
        .width = @floatFromInt(card_w),
        .height = @floatFromInt(card_h),
    };
    rl.drawRectangleRounded(card_rect, 0.02, 6, theme.bg_card);
    rl.drawRectangleRoundedLines(card_rect, 0.02, 6, theme.border);

    const pad: c_int = 40;
    const inner_w: c_int = card_w - pad * 2;
    var yy = cy + 30;

    // Title
    const title = "OmniBus";
    const title_w = rl.measureText(title, theme.font_title);
    rl.drawText(title, cx + @divTrunc(card_w - title_w, 2), yy, theme.font_title, theme.teal);
    yy += 40;

    // Subtitle
    const subtitle = "Post-Quantum Blockchain Wallet";
    const sub_w = rl.measureText(subtitle, theme.font_md);
    rl.drawText(subtitle, cx + @divTrunc(card_w - sub_w, 2), yy, theme.font_md, theme.text_secondary);
    yy += 30;

    // Separator
    rl.drawLine(cx + pad, yy, cx + card_w - pad, yy, theme.border);
    yy += 20;

    // Buttons
    const btn_h: c_int = 60;

    const r1 = btn.drawWide(cx + pad, yy, inner_w, btn_h, "  Create New Wallet", .primary, theme.font_lg);
    yy += btn_h + 4;
    rl.drawText("Generate a new mnemonic phrase and create a fresh wallet", cx + pad + 20, yy, 11, theme.text_dim);
    yy += 22;

    const r2 = btn.drawWide(cx + pad, yy, inner_w, btn_h, "  Import Existing Wallet", .secondary, theme.font_lg);
    yy += btn_h + 4;
    rl.drawText("Restore a wallet from a mnemonic phrase or backup file", cx + pad + 20, yy, 11, theme.text_dim);
    yy += 22;

    const r3 = btn.drawWide(cx + pad, yy, inner_w, btn_h, "  Connect to Running Node", .ghost, theme.font_lg);
    yy += btn_h + 4;
    rl.drawText("Use the wallet from an existing OmniBus node (spectator mode)", cx + pad + 20, yy, 11, theme.text_dim);

    // Version
    const version = "OmniBus-Zig v1.0.0 (Raylib)";
    const ver_w = rl.measureText(version, theme.font_xs);
    rl.drawText(version, cx + @divTrunc(card_w - ver_w, 2), cy + card_h - 30, theme.font_xs, theme.text_version);

    if (r1.clicked) return .create_wallet;
    if (r2.clicked) return .import_wallet;
    if (r3.clicked) return .connect_node;
    return .none;
}
