const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const log = std.log;

const xml = @import("xml");

const Sqlite = @import("sqlite.zig");
const parser = @import("xml_parser.zig");

const gl = @import("gl");
const Vec2 = gl.Vec2;
const c = gl.c;

const RGBA = gl.RGBA;

const Renderer = struct {
    pub var batch_rects: std.ArrayList([4]gl.BaseVertexData) = .empty;
    pub var batch_texts: std.ArrayList([4]gl.BaseVertexData) = .empty;

    pub fn render(_: *RendererContet) void {
        const self = ctx.user_data;
        _ = self;
        ctx.clear(.from_u32(0x303030ff));
        UI.push_layout();
        _ = UI.text_btn("Hello, World", 0.5);
        _ = UI.text_btn("AA", 0.5);
        _ = UI.text_btn("BB", 0.5);
        UI.pop_layout();

        UI.resolve_layout();
        render_ui();
        UI.reset_layout_tree();
        // draw_rect(.{ 0, 0 }, .{ 0.2, 0.2 }, .black);
        flush();
    }

    pub fn render_ui() void {
        render_ui_impl(UI.get_root_layout());
    }

    fn draw_rect(botleft: Vec2, size: Vec2, rgba: RGBA) void {
        batch_rects.append(gpa, ctx.make_rect_vertex_data(botleft, size, rgba)) catch unreachable;
    }

    fn render_ui_impl(node: *UI) void {
        const botleft = Vec2 {
            node.resolved_origin[0],
            node.resolved_origin[1] - node.resolved_size[1],
        };
        draw_rect(botleft, node.resolved_size, node.bg_color);

        if (node.flags.contains(.Layout)) {
            for (node.children.items) |child| {
                render_ui_impl(child);
            }
        } else {
            var it = ctx.make_code_point_vertex_data(botleft, node.font_scale, node.text, 1024*1024, .white);
            while (it.next()) |vertexes| {
                batch_texts.append(gpa, vertexes) catch unreachable;
            }
        }
    }

    fn flush() void {
        ctx.draw_tex_batch(batch_rects.items, ctx.white_tex, false, ctx.base_shader_pgm);
        ctx.draw_tex_batch(batch_texts.items, .{ .id = ctx.default_font.tex, .w = undefined, .h = undefined }, false, ctx.font_shader_pgm);

        // ctx.draw_text(.{ -0.5, -0.1}, 1, "Hello World", .yellow);
        // for (ui.batch_texts.items[1..]) |vertexes| {
        //     // std.testing.expectEqualDeep(ui.batch_texts.items[i], vertexes) catch unreachable;
        //     ctx.draw_tex_vertex_data(vertexes, .{ .id = ctx.default_font.tex, .w = undefined, .h = undefined }, false, ctx.font_shader_pgm);
        // }

        // std.log.debug("texts batch: {}", .{ui.batch_texts.items.len});

        batch_rects.clearRetainingCapacity();
        batch_texts.clearRetainingCapacity();

    }
};
const RendererContet = gl.Context(Renderer);

pub var gpa: Allocator = undefined; // @init_on_main
pub var ctx: RendererContet = undefined; // @init_on_main

const Box = struct {
    botleft: Vec2,
    size: Vec2,

    pub fn x_right(self: Box) f32 {
        return self.botleft[0] + self.size[0]; 
    }

    pub fn y_top(self: Box) f32 {
        return self.botleft[1] + self.size[1]; 
    }

    pub fn top(self: Box, perct: f32) f32 {
        return self.botleft[1] + (1-perct)*self.size[1];
    }

    // Create a box where,
    //
    //         |------|
    // (x,y) --|      | h
    //         |------|
    //            w   
    pub fn from_centerleft(centerleft: Vec2, size: Vec2) Box {
        const x, const y = centerleft;
        return .{
            .botleft = .{ x, y-size[1]/2 },
            .size = size,
        };
    }

    pub fn from_botleft(botleft: Vec2, size: Vec2) Box {
        return .{
            .botleft = botleft,
            .size = size,
        };
    }
    // return a text_offset that defines the offset from the botleft of the box where text should be drawn
};

pub const UI = struct {
    pub var ui_arena_state: std.heap.ArenaAllocator = undefined; // @init_on_main
    pub var ui_arena: Allocator = undefined; // @init_on_main

    flags: std.EnumSet(Flag) = std.EnumSet(Flag).initEmpty(),

    children: std.ArrayList(*UI) = .empty,
    text: []const u8 = "",
    font_scale: f32 = 1,
    bg_color: RGBA = .black,

    // resolve time fiels
    layout_offset: Vec2 = .{ 0, 0 },
    resolved_size: Vec2 = .{ 0, 0 },
    resolved_origin: Vec2 = .{ 0, 0 }, // for now, the origin of a box is its topleft corner

    pub const Flag = enum {
        Layout,
    };

    pub fn text_btn(text: []const u8, font_scale: f32) bool {
        const ui = new_default();     

        ui.text = text;
        ui.font_scale = font_scale;

        ui.add_to_layout();
        // ui.flags.setPresent(.Layout, )
        return false;
    }

    fn new_default() *UI {
        const new_layout = ui_arena.create(UI) catch unreachable;
        new_layout.* = UI {};
        return new_layout;
    }

    fn add_to_layout(ui: *UI) void {
        const layout = get_curr_layout();
        layout.children.append(ui_arena, ui) catch unreachable;
    }

    //
    // Layout
    //
    pub var layouts_stack: std.ArrayList(*UI) = .empty;
    pub var root_layout: *UI = undefined; // @init_on_main

    pub fn push_layout() void {
        const new_layout = new_default();
        new_layout.flags.setPresent(.Layout, true);

        if (layouts_stack.items.len == 0) {
            root_layout = new_layout;
        } else {
            new_layout.add_to_layout();
        }
        layouts_stack.append(gpa, new_layout) catch @panic("OOM");
    }

    pub fn pop_layout() void {
        _ = layouts_stack.pop().?;
    }

    fn get_curr_layout() *UI {
        const layout = layouts_stack.getLast();
        assert(layout.flags.contains(.Layout));

        return layout;
    }

    fn get_root_layout() *UI {
        assert(root_layout.flags.contains(.Layout));
        return root_layout;
    }

    pub fn resolve_layout() void {
        const root = get_root_layout();
        resolve_layout_impl(null, root);
    }

    pub fn reset_layout_tree() void {
        _ = ui_arena_state.reset(.retain_capacity);
        layouts_stack.clearRetainingCapacity();
    }


    // A recursive function to resolve layout
    // The origin of parent must be resolved before called.
    //
    // After this function, both the size and origin are resolved.
    fn resolve_layout_impl(maybe_parent: ?*const UI, node: *UI) void {
        if (maybe_parent) |parent| {
            assert(parent.flags.contains(.Layout));
            node.resolved_origin[0] = parent.resolved_origin[0] + parent.layout_offset[0];
            node.resolved_origin[1] = parent.resolved_origin[1] + parent.layout_offset[1];
        } else {
            // topleft corner of the screen
            node.resolved_origin[0] = ctx.x_left();
            node.resolved_origin[1] = ctx.y_top();
        }

        if (node.flags.contains(.Layout)) {
            var max_h: f32 = 0;
            for (node.children.items) |child| {
                // before recurring into this function, make sure the origin of `node` is resolved
                resolve_layout_impl(node, child);
                node.layout_offset[0] += child.resolved_size[0];
                max_h = @max(max_h, node.resolved_size[1]);
            }
            node.resolved_size[0] = @abs(node.layout_offset[0]);
            node.resolved_size[1] = max_h;
        } else if (node.text.len > 0) {
            node.resolved_size[0] = ctx.text_width(node.font_scale, node.text);
            node.resolved_size[1] = ctx.cal_font_h(node.font_scale);
        }

    }
};



pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    gpa = gpa_state.allocator();
    UI.ui_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer UI.ui_arena_state.deinit();
    UI.ui_arena = UI.ui_arena_state.allocator();

    var renderer = Renderer {};

    try RendererContet.init(&ctx, &renderer, Renderer.render, "rss-reader", 1920, 1024, gpa);
    while (!ctx.window_should_close()) {

        ctx.render();
    }
}
