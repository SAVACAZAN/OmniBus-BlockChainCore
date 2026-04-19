// Thin Zig wrapper over raylib C API
pub const c = @cImport({
    @cInclude("raylib.h");
});

// Re-export commonly used types
pub const Color = c.Color;
pub const Rectangle = c.Rectangle;
pub const Vector2 = c.Vector2;

// ─── Window ───
pub fn initWindow(w: c_int, h: c_int, title: [*:0]const u8) void {
    c.InitWindow(w, h, title);
}
pub fn closeWindow() void { c.CloseWindow(); }
pub fn windowShouldClose() bool { return c.WindowShouldClose(); }
pub fn setTargetFPS(fps: c_int) void { c.SetTargetFPS(fps); }

// ─── Drawing ───
pub fn beginDrawing() void { c.BeginDrawing(); }
pub fn endDrawing() void { c.EndDrawing(); }
pub fn clearBackground(color: Color) void { c.ClearBackground(color); }

// ─── Shapes ───
pub fn drawRectangle(x: c_int, y: c_int, w: c_int, h: c_int, color: Color) void {
    c.DrawRectangle(x, y, w, h, color);
}
pub fn drawRectangleRec(rec: Rectangle, color: Color) void {
    c.DrawRectangleRec(rec, color);
}
pub fn drawRectangleRounded(rec: Rectangle, roundness: f32, segments: c_int, color: Color) void {
    c.DrawRectangleRounded(rec, roundness, segments, color);
}
pub fn drawRectangleRoundedLines(rec: Rectangle, roundness: f32, segments: c_int, color: Color) void {
    c.DrawRectangleRoundedLinesEx(rec, roundness, segments, 1.0, color);
}
pub fn drawLine(x1: c_int, y1: c_int, x2: c_int, y2: c_int, color: Color) void {
    c.DrawLine(x1, y1, x2, y2, color);
}

// ─── Text ───
pub fn drawText(text: [*:0]const u8, x: c_int, y: c_int, fontSize: c_int, color: Color) void {
    c.DrawText(text, x, y, fontSize, color);
}
pub fn measureText(text: [*:0]const u8, fontSize: c_int) c_int {
    return c.MeasureText(text, fontSize);
}

// ─── Input ───
pub fn getMouseX() c_int { return c.GetMouseX(); }
pub fn getMouseY() c_int { return c.GetMouseY(); }
pub fn isMouseButtonPressed(button: c_int) bool { return c.IsMouseButtonPressed(button); }
pub fn isMouseButtonDown(button: c_int) bool { return c.IsMouseButtonDown(button); }
pub fn isMouseButtonReleased(button: c_int) bool { return c.IsMouseButtonReleased(button); }

pub fn getCharPressed() c_int { return c.GetCharPressed(); }
pub fn isKeyPressed(key: c_int) bool { return c.IsKeyPressed(key); }
pub fn isKeyDown(key: c_int) bool { return c.IsKeyDown(key); }
pub fn isKeyPressedRepeat(key: c_int) bool { return c.IsKeyPressedRepeat(key); }
pub fn getFrameTime() f32 { return c.GetFrameTime(); }

// ─── Window state ───
pub fn setWindowState(flags: c_uint) void { c.SetWindowState(flags); }
pub fn setWindowMinSize(w: c_int, h: c_int) void { c.SetWindowMinSize(w, h); }
pub fn getScreenWidth() c_int { return c.GetScreenWidth(); }
pub fn getScreenHeight() c_int { return c.GetScreenHeight(); }
pub fn getMonitorWidth(monitor: c_int) c_int { return c.GetMonitorWidth(monitor); }
pub fn getMonitorHeight(monitor: c_int) c_int { return c.GetMonitorHeight(monitor); }
pub fn maximizeWindow() void { c.MaximizeWindow(); }

// Flags
pub const FLAG_WINDOW_RESIZABLE: c_uint = 0x00000004;
pub const FLAG_WINDOW_MAXIMIZED: c_uint = 0x00000400;

// ─── Constants ───
pub const MOUSE_LEFT: c_int = 0;
pub const KEY_BACKSPACE: c_int = 259;
pub const KEY_ENTER: c_int = 257;
pub const KEY_ESCAPE: c_int = 256;
pub const KEY_TAB: c_int = 258;
