const std = @import("std");
const gl = @import("gl.zig");

const Context = struct {

};

const GLContext = gl.Context(Context);
fn render(ctx: GLContext) void {
    ctx.draw_rect(.{ -0.5, 0.5 }, 1, 1);
}

pub fn main() !void {
    var user_data = Context {};
    var ctx: GLContext = undefined;
    try ctx.init(&user_data, render, "Hello from renderer", 1920, 1024);

    while (!ctx.window_should_close()) {
        ctx.render();
    }

    ctx.close_window();
}
