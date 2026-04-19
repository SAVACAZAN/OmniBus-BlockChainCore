const rl = @import("../raylib.zig");
const theme = @import("../theme.zig");

pub const TextInput = struct {
    buffer: [256]u8 = [_]u8{0} ** 256,
    len: usize = 0,
    focused: bool = false,
    password_mode: bool = false,
    cursor_blink: f32 = 0,

    pub fn getText(self: *const TextInput) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn clear(self: *TextInput) void {
        self.len = 0;
        @memset(&self.buffer, 0);
    }

    pub fn draw(
        self: *TextInput,
        x: c_int,
        y: c_int,
        w: c_int,
        h: c_int,
        label: [*:0]const u8,
        placeholder: [*:0]const u8,
    ) void {
        // Label
        rl.drawText(label, x, y - 18, theme.font_sm, theme.text_secondary);

        // Focus detection
        const mx = rl.getMouseX();
        const my = rl.getMouseY();
        if (rl.isMouseButtonPressed(rl.MOUSE_LEFT)) {
            self.focused = mx >= x and mx < x + w and my >= y and my < y + h;
        }

        // Background + border
        const hf: f32 = @floatFromInt(h);
        const rect = rl.Rectangle{ .x = @floatFromInt(x), .y = @floatFromInt(y), .width = @floatFromInt(w), .height = hf };
        rl.drawRectangleRounded(rect, theme.input_rounding / hf, 6, theme.bg_input);
        const border_color = if (self.focused) theme.border_focus else theme.border;
        rl.drawRectangleRoundedLines(rect, theme.input_rounding / hf, 6, border_color);

        if (self.focused) {
            // Keyboard input
            var char_pressed = rl.getCharPressed();
            while (char_pressed != 0) {
                if (char_pressed >= 32 and char_pressed < 127 and self.len < 255) {
                    self.buffer[self.len] = @intCast(@as(u32, @bitCast(char_pressed)));
                    self.len += 1;
                }
                char_pressed = rl.getCharPressed();
            }

            if (rl.isKeyPressed(rl.KEY_BACKSPACE) or (rl.isKeyDown(rl.KEY_BACKSPACE) and rl.isKeyPressedRepeat(rl.KEY_BACKSPACE))) {
                if (self.len > 0) {
                    self.len -= 1;
                    self.buffer[self.len] = 0;
                }
            }

            self.cursor_blink += rl.getFrameTime();
            if (self.cursor_blink > 1.0) self.cursor_blink = 0;
        }

        const tx = x + 8;
        const ty = y + @divTrunc(h - theme.font_md, 2);

        if (self.len == 0) {
            rl.drawText(placeholder, tx, ty, theme.font_md, theme.text_muted);
        } else {
            var display: [257]u8 = undefined;
            if (self.password_mode) {
                for (0..self.len) |i| display[i] = '*';
            } else {
                @memcpy(display[0..self.len], self.buffer[0..self.len]);
            }
            display[self.len] = 0;
            rl.drawText(@ptrCast(&display), tx, ty, theme.font_md, theme.text_primary);
        }

        // Cursor
        if (self.focused and self.cursor_blink < 0.5) {
            var measure_buf: [257]u8 = undefined;
            if (self.password_mode) {
                for (0..self.len) |i| measure_buf[i] = '*';
            } else {
                @memcpy(measure_buf[0..self.len], self.buffer[0..self.len]);
            }
            measure_buf[self.len] = 0;
            const text_w = rl.measureText(@ptrCast(&measure_buf), theme.font_md);
            rl.drawLine(tx + text_w + 1, y + 4, tx + text_w + 1, y + h - 4, theme.text_primary);
        }
    }
};
