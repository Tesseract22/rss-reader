const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("gl");

pub var ctx: gl.Context = undefined; // @init_on_main
pub fn render(_: *gl.Context) void {
    ctx.clear(.black);
    ctx.draw_circle_lines(.{ 0, 0 }, 0.5, 2, .red);
    // ctx.draw_circle_sector(.{ 0, 0 }, 0.3, 50, 0, std.math.pi, .white);
    ctx.draw_rect_rounded_lines(.{ -0.3, -0.3 }, .{ 0.6, 0.6 }, 0.2, 2, .yellow);
}
pub var gpa: Allocator = undefined; // @init_on_main
pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    gpa = gpa_state.allocator();

    try gl.Context.init(&ctx, render, "RSS Reader", 1920, 1024, gpa);
    while (!ctx.window_should_close()) {
        while (ctx.poll_event()) |_| {}
    }
}
