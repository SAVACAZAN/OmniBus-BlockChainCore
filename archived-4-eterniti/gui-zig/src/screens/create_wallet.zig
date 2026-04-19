const std = @import("std");
const rl = @import("../raylib.zig");
const theme = @import("../theme.zig");
const btn = @import("../widgets/button.zig");
const TextInput = @import("../widgets/text_input.zig").TextInput;

pub const CreateStep = enum { name_password, show_mnemonic, done };

pub const CreateWalletScreen = struct {
    step: CreateStep = .name_password,
    name_input: TextInput = .{},
    password_input: TextInput = .{ .password_mode = true },
    confirm_input: TextInput = .{ .password_mode = true },
    mnemonic_words: [12][16]u8 = undefined,
    backed_up: bool = false,
    error_msg: [128]u8 = [_]u8{0} ** 128,
    error_len: usize = 0,

    pub fn init() CreateWalletScreen {
        var s = CreateWalletScreen{};
        const demo = [12][]const u8{
            "abandon", "ability", "able",    "about",
            "above",   "absent",  "absorb",  "abstract",
            "absurd",  "abuse",   "access",  "accident",
        };
        for (0..12) |i| {
            @memset(&s.mnemonic_words[i], 0);
            @memcpy(s.mnemonic_words[i][0..demo[i].len], demo[i]);
        }
        return s;
    }

    pub fn draw(self: *CreateWalletScreen, screen_w: c_int, screen_h: c_int) bool {
        return switch (self.step) {
            .name_password => self.drawNamePassword(screen_w, screen_h),
            .show_mnemonic => self.drawShowMnemonic(screen_w, screen_h),
            .done => true,
        };
    }

    fn drawNamePassword(self: *CreateWalletScreen, screen_w: c_int, screen_h: c_int) bool {
        const card_w: c_int = 500;
        const card_h: c_int = 440;
        const cx = @divTrunc(screen_w - card_w, 2);
        const cy = @divTrunc(screen_h - card_h, 2);
        const pad: c_int = 40;
        const inner_w: c_int = card_w - pad * 2;

        rl.drawRectangle(0, 0, screen_w, screen_h, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 120 });

        const card_rect = rl.Rectangle{ .x = @floatFromInt(cx), .y = @floatFromInt(cy), .width = @floatFromInt(card_w), .height = @floatFromInt(card_h) };
        rl.drawRectangleRounded(card_rect, 0.02, 6, theme.bg_card);
        rl.drawRectangleRoundedLines(card_rect, 0.02, 6, theme.border);

        var yy = cy + 25;

        const title = "Create New Wallet";
        const tw = rl.measureText(title, theme.font_xl);
        rl.drawText(title, cx + @divTrunc(card_w - tw, 2), yy, theme.font_xl, theme.teal);
        yy += 35;

        rl.drawText("Step 1 of 2 - Name & Password", cx + pad, yy, theme.font_sm, theme.text_secondary);
        yy += 25;

        yy += 18;
        self.name_input.draw(cx + pad, yy, inner_w, 36, "Wallet Name", "My OmniBus Wallet");
        yy += 50;

        yy += 18;
        self.password_input.draw(cx + pad, yy, inner_w, 36, "Password (min 8 chars)", "Enter password");
        yy += 50;

        yy += 18;
        self.confirm_input.draw(cx + pad, yy, inner_w, 36, "Confirm Password", "Confirm password");
        yy += 50;

        if (self.error_len > 0) {
            var err: [129]u8 = undefined;
            @memcpy(err[0..self.error_len], self.error_msg[0..self.error_len]);
            err[self.error_len] = 0;
            rl.drawText(@ptrCast(&err), cx + pad, yy, theme.font_sm, theme.danger);
            yy += 20;
        }

        yy += 5;
        const result = btn.draw(cx + pad, yy, inner_w, 44, "Next  ->", .primary, theme.font_lg);

        if (result.clicked) {
            const name = self.name_input.getText();
            const pass = self.password_input.getText();
            const conf = self.confirm_input.getText();

            if (name.len == 0) {
                self.setError("Wallet name cannot be empty");
            } else if (pass.len < 8) {
                self.setError("Password must be at least 8 characters");
            } else if (!std.mem.eql(u8, pass, conf)) {
                self.setError("Passwords do not match");
            } else {
                self.error_len = 0;
                self.step = .show_mnemonic;
            }
        }
        return false;
    }

    fn drawShowMnemonic(self: *CreateWalletScreen, screen_w: c_int, screen_h: c_int) bool {
        const card_w: c_int = 580;
        const card_h: c_int = 480;
        const cx = @divTrunc(screen_w - card_w, 2);
        const cy = @divTrunc(screen_h - card_h, 2);
        const pad: c_int = 40;
        const inner_w: c_int = card_w - pad * 2;

        rl.drawRectangle(0, 0, screen_w, screen_h, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 120 });

        const card_rect = rl.Rectangle{ .x = @floatFromInt(cx), .y = @floatFromInt(cy), .width = @floatFromInt(card_w), .height = @floatFromInt(card_h) };
        rl.drawRectangleRounded(card_rect, 0.02, 6, theme.bg_card);
        rl.drawRectangleRoundedLines(card_rect, 0.02, 6, theme.border);

        var yy = cy + 25;

        const title = "Your Recovery Phrase";
        const tw = rl.measureText(title, theme.font_xl);
        rl.drawText(title, cx + @divTrunc(card_w - tw, 2), yy, theme.font_xl, theme.teal);
        yy += 30;

        rl.drawText("Step 2 of 2 - Write down these words in order", cx + pad, yy, theme.font_sm, theme.text_secondary);
        yy += 18;
        rl.drawText("WARNING: Never share your mnemonic. Store it safely offline.", cx + pad, yy, 11, theme.danger);
        yy += 25;

        // 3x4 grid of words
        const col_w = @divTrunc(inner_w, 3);
        for (0..12) |i| {
            const col: c_int = @intCast(i % 3);
            const row: c_int = @intCast(i / 3);
            const wx = cx + pad + col * col_w;
            const wy = yy + row * 32;

            // Number
            var num_buf: [8]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}.", .{i + 1}) catch "?.";
            // null-terminate for C
            var num_z: [8]u8 = [_]u8{0} ** 8;
            @memcpy(num_z[0..num_str.len], num_str);
            rl.drawText(@ptrCast(&num_z), wx, wy, theme.font_sm, theme.text_muted);

            // Word
            var word: [17]u8 = undefined;
            var wl: usize = 0;
            for (self.mnemonic_words[i]) |ch| {
                if (ch == 0) break;
                word[wl] = ch;
                wl += 1;
            }
            word[wl] = 0;
            rl.drawText(@ptrCast(&word), wx + 28, wy, theme.font_md, theme.teal_bright);
        }

        yy += 4 * 32 + 15;

        // Checkbox
        const chk_x = cx + pad;
        const chk_size: c_int = 18;
        const chk_rect = rl.Rectangle{ .x = @floatFromInt(chk_x), .y = @floatFromInt(yy), .width = @floatFromInt(chk_size), .height = @floatFromInt(chk_size) };
        rl.drawRectangleRounded(chk_rect, 0.2, 4, theme.bg_input);
        rl.drawRectangleRoundedLines(chk_rect, 0.2, 4, theme.border);

        if (self.backed_up) {
            rl.drawText("X", chk_x + 4, yy + 1, theme.font_md, theme.teal);
        }

        {
            const mx = rl.getMouseX();
            const my = rl.getMouseY();
            if (rl.isMouseButtonPressed(rl.MOUSE_LEFT) and
                mx >= chk_x and mx < chk_x + chk_size + 250 and
                my >= yy and my < yy + chk_size)
            {
                self.backed_up = !self.backed_up;
            }
        }

        rl.drawText("I have safely backed up my recovery phrase", chk_x + chk_size + 8, yy + 2, theme.font_sm, theme.text_primary);
        yy += 35;

        if (self.backed_up) {
            const r = btn.draw(cx + pad, yy, inner_w, 44, "Create Wallet", .primary, theme.font_lg);
            if (r.clicked) {
                self.step = .done;
                return true;
            }
        } else {
            const gr = rl.Rectangle{ .x = @floatFromInt(cx + pad), .y = @floatFromInt(yy), .width = @floatFromInt(inner_w), .height = 44.0 };
            rl.drawRectangleRounded(gr, 0.1, 6, theme.bg_panel);
            const gt = "Create Wallet";
            const gtw = rl.measureText(gt, theme.font_lg);
            rl.drawText(gt, cx + pad + @divTrunc(inner_w - gtw, 2), yy + 13, theme.font_lg, theme.text_muted);
        }

        return false;
    }

    fn setError(self: *CreateWalletScreen, msg: []const u8) void {
        const n = @min(msg.len, 127);
        @memcpy(self.error_msg[0..n], msg[0..n]);
        self.error_len = n;
    }
};
