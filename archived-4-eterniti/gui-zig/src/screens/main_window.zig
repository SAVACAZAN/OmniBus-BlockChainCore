const rl = @import("../raylib.zig");
const theme = @import("../theme.zig");
const btn = @import("../widgets/button.zig");

pub const Tab = enum {
    overview,
    send,
    receive,
    transactions,
    multi_wallet,
    block_explorer,
    mining,
    network,
    console,
};

const tab_names = [_][*:0]const u8{
    "Overview",       "Send",     "Receive", "Transactions",
    "Multi-Wallet",   "Block Explorer", "Mining",
    "Network",        "Console",
};

const tab_values = [_]Tab{
    .overview,       .send,     .receive, .transactions,
    .multi_wallet,   .block_explorer, .mining,
    .network,        .console,
};

pub var current_tab: Tab = .overview;

pub fn draw(screen_w: c_int, screen_h: c_int) void {
    // Header
    const header_h: c_int = 48;
    rl.drawRectangle(0, 0, screen_w, header_h, theme.bg_dark);
    rl.drawLine(0, header_h, screen_w, header_h, theme.border);
    rl.drawText("OmniBus", 16, 12, theme.font_xl, theme.teal);
    rl.drawText("Wallet: Active", screen_w - 200, 8, theme.font_sm, theme.success);
    rl.drawText("ob1q...demo", screen_w - 200, 24, theme.font_xs, theme.text_secondary);

    // Tab bar
    const tab_y: c_int = header_h;
    const tab_h: c_int = 36;
    rl.drawRectangle(0, tab_y, screen_w, tab_h, theme.bg_panel);
    rl.drawLine(0, tab_y + tab_h, screen_w, tab_y + tab_h, theme.border);

    var tx: c_int = 8;
    for (tab_names, 0..) |name, i| {
        const tw = rl.measureText(name, theme.font_sm) + 24;
        const is_active = tab_values[i] == current_tab;
        const mx = rl.getMouseX();
        const my = rl.getMouseY();
        const hovered = mx >= tx and mx < tx + tw and my >= tab_y and my < tab_y + tab_h;

        if (is_active) {
            rl.drawRectangle(tx, tab_y, tw, tab_h, theme.bg_dark);
            rl.drawRectangle(tx, tab_y + tab_h - 2, tw, 2, theme.accent);
        } else if (hovered) {
            rl.drawRectangle(tx, tab_y, tw, tab_h, theme.bg_hover);
        }

        const color = if (is_active) theme.text_primary else theme.text_secondary;
        rl.drawText(name, tx + 12, tab_y + 10, theme.font_sm, color);

        if (hovered and rl.isMouseButtonPressed(rl.MOUSE_LEFT)) {
            current_tab = tab_values[i];
        }
        tx += tw + 2;
    }

    // Content
    const content_y = header_h + tab_h + 1;

    switch (current_tab) {
        .overview => drawOverview(screen_w, content_y),
        .multi_wallet => drawMultiWallet(screen_w, content_y),
        else => drawPlaceholder(screen_w, content_y),
    }

    // Status bar
    const status_y = screen_h - 28;
    rl.drawRectangle(0, status_y, screen_w, 28, theme.bg_dark);
    rl.drawLine(0, status_y, screen_w, status_y, theme.border);
    rl.drawText("Block: #0  |  Peers: 0  |  Mempool: 0 tx", 12, status_y + 7, theme.font_xs, theme.text_muted);

    const node_txt = "Node: Disconnected";
    const ntw = rl.measureText(node_txt, theme.font_xs);
    rl.drawText(node_txt, screen_w - ntw - 12, status_y + 7, theme.font_xs, theme.warning);
}

fn drawOverview(screen_w: c_int, start_y: c_int) void {
    var yy = start_y + theme.padding;
    const pad = theme.padding * 2;
    const card_w = screen_w - pad * 2;

    const card_rect = rl.Rectangle{
        .x = @floatFromInt(pad),
        .y = @floatFromInt(yy),
        .width = @floatFromInt(card_w),
        .height = 120,
    };
    rl.drawRectangleRounded(card_rect, 0.02, 6, theme.bg_card);
    rl.drawRectangleRoundedLines(card_rect, 0.02, 6, theme.border);

    rl.drawText("Total Balance", pad + 20, yy + 15, theme.font_sm, theme.text_secondary);
    rl.drawText("0.00000000 OMNI", pad + 20, yy + 38, 28, theme.teal);
    rl.drawText("$0.00 USD", pad + 20, yy + 75, theme.font_md, theme.text_dim);
    yy += 140;

    rl.drawText("Quick Actions", pad, yy, theme.font_lg, theme.text_primary);
    yy += 30;

    _ = btn.draw(pad, yy, 150, 40, "Send", .primary, theme.font_md);
    _ = btn.draw(pad + 162, yy, 150, 40, "Receive", .secondary, theme.font_md);
    _ = btn.draw(pad + 324, yy, 150, 40, "New Address", .secondary, theme.font_md);
    yy += 60;

    rl.drawText("Recent Transactions", pad, yy, theme.font_lg, theme.text_primary);
    yy += 30;
    rl.drawText("No transactions yet", pad + 20, yy, theme.font_sm, theme.text_muted);
}

fn drawMultiWallet(screen_w: c_int, start_y: c_int) void {
    var yy = start_y + theme.padding;
    const pad = theme.padding * 2;

    rl.drawText("Multi-Chain Wallet", pad, yy, theme.font_xl, theme.teal);
    yy += 30;
    rl.drawText("Addresses derived from same BIP-39 seed across 15+ chains", pad, yy, theme.font_sm, theme.text_secondary);
    yy += 30;

    const chains = [_]struct { name: [*:0]const u8, prefix: [*:0]const u8, color: rl.Color }{
        .{ .name = "OMNI  (omnibus.omni)", .prefix = "ob1q...", .color = theme.teal },
        .{ .name = "OMNI  (omnibus.love)", .prefix = "ob_k1_1...", .color = theme.teal_bright },
        .{ .name = "OMNI  (omnibus.food)", .prefix = "ob_f5_1...", .color = theme.teal_bright },
        .{ .name = "OMNI  (omnibus.rent)", .prefix = "ob_d5_1...", .color = theme.teal_bright },
        .{ .name = "OMNI  (omnibus.vacation)", .prefix = "ob_s3_1...", .color = theme.teal_bright },
        .{ .name = "BTC   (Legacy P2PKH)", .prefix = "1...", .color = theme.btc_orange },
        .{ .name = "BTC   (SegWit P2SH)", .prefix = "3...", .color = theme.btc_orange },
        .{ .name = "BTC   (Native SegWit)", .prefix = "bc1q...", .color = theme.btc_orange },
        .{ .name = "BTC   (Taproot)", .prefix = "bc1p...", .color = theme.btc_orange },
        .{ .name = "ETH", .prefix = "0x...", .color = theme.eth_blue },
        .{ .name = "BNB", .prefix = "0x...", .color = theme.bnb_yellow },
        .{ .name = "SOL", .prefix = "...", .color = theme.sol_purple },
        .{ .name = "ADA", .prefix = "addr1...", .color = theme.ada_blue },
        .{ .name = "DOT", .prefix = "1...", .color = theme.dot_pink },
        .{ .name = "LTC", .prefix = "ltc1q...", .color = theme.text_primary },
        .{ .name = "DOGE", .prefix = "D...", .color = theme.warning },
    };

    for (chains, 0..) |chain, i| {
        const row_w = screen_w - pad * 2;
        if (i % 2 == 0) {
            rl.drawRectangle(pad, yy, row_w, 28, rl.Color{ .r = 0x16, .g = 0x18, .b = 0x29, .a = 0xff });
        }
        rl.drawText(chain.name, pad + 10, yy + 6, theme.font_sm, chain.color);
        rl.drawText(chain.prefix, pad + 280, yy + 6, theme.font_sm, theme.purple_addr);
        yy += 28;
    }
}

fn drawPlaceholder(screen_w: c_int, start_y: c_int) void {
    const text = "Coming soon...";
    const tw = rl.measureText(text, theme.font_xl);
    rl.drawText(text, @divTrunc(screen_w - tw, 2), start_y + 100, theme.font_xl, theme.text_muted);
}
