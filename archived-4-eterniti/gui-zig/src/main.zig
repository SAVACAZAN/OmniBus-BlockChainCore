const rl = @import("raylib.zig");
const theme = @import("theme.zig");
const welcome = @import("screens/welcome.zig");
const create_wallet = @import("screens/create_wallet.zig");
const main_window = @import("screens/main_window.zig");

// ═══════════════════════════════════════════════════════════════
//  OmniBus GUI — Zig + Raylib native wallet
// ═══════════════════════════════════════════════════════════════

const AppScreen = enum {
    welcome,
    create_wallet,
    import_wallet,
    main_window,
};

pub fn main() void {
    rl.setWindowState(rl.FLAG_WINDOW_RESIZABLE);
    rl.initWindow(1280, 800, "OmniBus Wallet \xe2\x80\x94 Zig/Raylib");
    defer rl.closeWindow();
    rl.setWindowMinSize(1024, 600);
    rl.maximizeWindow();
    rl.setTargetFPS(60);

    var app_screen: AppScreen = .welcome;
    var create_screen = create_wallet.CreateWalletScreen.init();

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();

        // Dynamic screen size (resizable window)
        const sw = rl.getScreenWidth();
        const sh = rl.getScreenHeight();

        rl.clearBackground(theme.bg_main);

        switch (app_screen) {
            .welcome => {
                main_window.draw(sw, sh);
                const choice = welcome.draw(sw, sh);
                switch (choice) {
                    .create_wallet => {
                        create_screen = create_wallet.CreateWalletScreen.init();
                        app_screen = .create_wallet;
                    },
                    .import_wallet => app_screen = .import_wallet,
                    .connect_node => app_screen = .main_window,
                    .none => {},
                }
            },
            .create_wallet => {
                main_window.draw(sw, sh);
                const done = create_screen.draw(sw, sh);
                if (done) app_screen = .main_window;
            },
            .import_wallet => {
                main_window.draw(sw, sh);
                rl.drawRectangle(0, 0, sw, sh, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 120 });
                const text = "Import Wallet \xe2\x80\x94 Coming Soon";
                const tw = rl.measureText(text, theme.font_xl);
                rl.drawText(text, @divTrunc(sw - tw, 2), @divTrunc(sh, 2), theme.font_xl, theme.teal);
                if (rl.isKeyPressed(rl.KEY_ENTER) or rl.isKeyPressed(rl.KEY_ESCAPE)) {
                    app_screen = .main_window;
                }
            },
            .main_window => {
                main_window.draw(sw, sh);
            },
        }
    }
}
