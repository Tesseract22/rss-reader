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
    pub var batches: std.ArrayList([4]gl.BaseVertexData) = .empty;
    pub var batches_state: std.ArrayList(struct { BatchState, u64 }) = .empty;
    pub const BatchState = struct {
        tex: gl.Texture,
        border_thickness: ?f32,
        shader: gl.GLObj,
    };

    pub var counter: usize = 0;

    pub fn render(_: *RendererContet) void {
        const self = ctx.user_data;
        _ = self;
        ctx.clear(.from_u32(0x303030ff));
        {
            UI.push_layout(.X);
            if (UI.text_btn(std.fmt.allocPrint(UI.curr_arena, "counter {}", .{ counter }) catch unreachable, 0.5)) {
                counter += 1;
            }
            _ = UI.text_btn("AA", 0.5);
            _ = UI.text_btn("BB", 0.5);

            UI.push_layout(.Y);
            _ = UI.text_btn("CC", 0.5);
            _ = UI.text_btn("DD", 0.5);
            UI.pop_layout();

            UI.pop_layout();
        }

        UI.resolve_layout();
        render_ui();
        UI.reset_layout_tree();
        // draw_rect(.{ 0, 0 }, .{ 0.2, 0.2 }, .black);
        flush();
    }

    pub fn render_ui() void {
        render_ui_impl(UI.get_root_layout());
    }

    fn render_ui_impl(node: *UI) void {
        const box = Box.from_topleft(node.resolved_origin, node.resolved_size);
        draw_rect(box.botleft, node.resolved_size, node.bg_color);
        if (node.mouse_state.contains(.Down)) {
            draw_rect(box.botleft, node.resolved_size, .from_u32(0x00000030));
        } else if (node.mouse_state.contains(.Hover)) {
            draw_rect(box.botleft, node.resolved_size, .from_u32(0xffffff30));
        }


        if (node.flags.contains(.Layout)) {
            for (node.children.items) |child| {
                render_ui_impl(child);
            }
        } else {
            draw_text(.{ box.botleft[0]+ctx.pixels(node.padding[0]), box.botleft[1]+ctx.pixels(node.padding[1]) }, node.font_scale, node.text, .white);
        }
        draw_rect_lines(box.botleft, box.size, 2.5, node.border_color);
    }

    fn append_state(ct: usize) void {
        const last_state_ct = &batches_state.items[batches_state.items.len - 1];
        last_state_ct[1] += ct;
    }

    fn switch_or_append_state(new_state: BatchState, ct: usize) void {
        if (batches_state.items.len > 0) {
            const last_state_ct = &batches_state.items[batches_state.items.len - 1];
            if (std.meta.eql(last_state_ct.*[0], new_state)) {
                append_state(ct);
                return;
            }
        }
        batches_state.append(gpa, .{ new_state, ct }) catch unreachable;
    }

    fn draw_rect(botleft: Vec2, size: Vec2, rgba: RGBA) void {
        switch_or_append_state(
            .{ .tex = ctx.white_tex, .border_thickness = null, .shader = ctx.base_shader_pgm }, 1); 
        batches.append(gpa, ctx.make_rect_vertex_data(botleft, size, rgba)) catch unreachable;
    }

    fn draw_rect_lines(botleft: Vec2, size: Vec2, thickness: f32, rgba: RGBA) void {
        switch_or_append_state(
            .{ .tex = ctx.white_tex, .border_thickness = thickness, .shader = ctx.base_shader_pgm }, 1); 
        batches.append(gpa, ctx.make_rect_vertex_data(botleft, size, rgba)) catch unreachable;
    }

    fn draw_text(pos: Vec2, font_scale: f32, text: []const u8, rgba: RGBA) void {
        switch_or_append_state(
            .{ .tex = .{ .id = ctx.default_font.tex, .w = undefined, .h = undefined }, .border_thickness = null, .shader = ctx.font_shader_pgm }, 0);
        var it = ctx.make_code_point_vertex_data(pos, font_scale, text, 1024*1024, rgba);
        while (it.next()) |vertexes| {
            append_state(1);
            batches.append(gpa, vertexes) catch unreachable;
        }
    }

    fn flush() void {
        var count: u64 = 0;
        for (batches_state.items) |state_ct| {
            ctx.draw_tex_batch(batches.items[count..count+state_ct[1]], state_ct[0].tex, state_ct[0].border_thickness, state_ct[0].shader);
            count += state_ct[1];
        }

        batches.clearRetainingCapacity();
        batches_state.clearRetainingCapacity();
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

    pub fn from_topleft(topleft: Vec2, size: Vec2) Box {
        return .{
            .botleft = .{ topleft[0], topleft[1] - size[1] },
            .size = size,
        };
    }
    // return a text_offset that defines the offset from the botleft of the box where text should be drawn
};

pub const UI = struct {
    pub var key_hash: [2]std.StringHashMap(*UI) = undefined; // @init_on_main
    pub var curr_hash: *std.StringHashMap(*UI) = undefined; // @init_on_main
    pub var prev_hash: *std.StringHashMap(*UI) = undefined; // @init_on_main

    pub var ui_arena_state: [2]std.heap.ArenaAllocator = undefined; // @init_on_main
    pub var curr_arena_state: *std.heap.ArenaAllocator = undefined; // @init_on_main
    pub var prev_arena_state: *std.heap.ArenaAllocator = undefined; // @init_on_main
    pub var curr_arena: Allocator = undefined; // @init_on_main
    pub var prev_arena: Allocator = undefined; // @init_on_main

    flags: std.EnumSet(Flag) = std.EnumSet(Flag).initEmpty(),

    children: std.ArrayList(*UI) = .empty,
    text: []const u8 = "",
    font_scale: f32 = 1,
    bg_color: RGBA = .transparent,
    border_color: RGBA = .from_u32(0x7f7f7fff),
    padding: Vec2 = .{ 10, 10 },

    // resolve time fiels
    layout_offset: Vec2 = .{ 0, 0 },
    layout_axis: Axis = .X,
    resolved_size: Vec2 = .{ 0, 0 },
    resolved_origin: Vec2 = .{ 0, 0 }, // for now, the origin of a box is its topleft corner

    mouse_state: std.EnumSet(MouseState) = .initEmpty(),
    
    pub const Axis = enum(u8) {
        X = 0,
        Y = 1,
    };

    pub const Flag = enum {
        Layout,
    };

    pub const MouseState = enum {
        Hover,
        Down,
        Clicked,
    };

    fn within_rect(p: Vec2, box: Box) bool {
        const botleft = box.botleft;
        const size = box.size;
        return p[0] >= botleft[0] and p[1] >= botleft[1]
            and p[0] <= botleft[0] + size[0] and p[1] <= botleft[1] + size[1];
    }

    fn mouse_within_rect(box: Box) bool {
        return within_rect(ctx.mouse_pos_gl, box);
    }

    pub fn text_btn(text: []const u8, font_scale: f32) bool {
        const ui = new_default();     

        ui.text = text;
        ui.font_scale = font_scale;

        ui.add_to_layout();

        curr_hash.putNoClobber(text, ui) catch unreachable;

        const prev_ui = prev_hash.get(text) orelse return false;
        
        const hover = mouse_within_rect(.from_topleft(prev_ui.resolved_origin, prev_ui.resolved_size));
        ui.mouse_state.setPresent(.Hover, hover);
        ui.mouse_state.setPresent(.Clicked, hover and ctx.mouse_left);
        ui.mouse_state.setPresent(.Down, hover and c.RGFW_isMouseDown(c.RGFW_mouseLeft) == 1);

        return ui.mouse_state.contains(.Clicked);
    }

    fn new_default() *UI {
        const new_layout = curr_arena.create(UI) catch unreachable;
        new_layout.* = UI {};
        return new_layout;
    }

    fn add_to_layout(ui: *UI) void {
        const layout = get_curr_layout();
        layout.children.append(curr_arena, ui) catch unreachable;
    }

    //
    // Layout
    //
    pub var layouts_stack: std.ArrayList(*UI) = .empty;
    pub var root_layout: *UI = undefined; // @init_on_main

    pub fn push_layout(axis: Axis) void {
        const new_layout = new_default();
        new_layout.flags.setPresent(.Layout, true);
        new_layout.layout_axis = axis;
        // new_layout.border_color = .transparent;

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
        prev_hash.clearRetainingCapacity();
        std.mem.swap(std.StringHashMap(*UI), prev_hash, curr_hash);

        _ = prev_arena_state.reset(.retain_capacity);
        std.mem.swap(std.heap.ArenaAllocator, prev_arena_state, curr_arena_state);
        curr_arena = curr_arena_state.allocator();
        prev_arena = prev_arena_state.allocator();

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
            node.layout_offset[0] += ctx.pixels(node.padding[0]);
            node.layout_offset[1] -= ctx.pixels(node.padding[1]);
            for (node.children.items) |child| {
                // before recurring into this function, make sure the origin of `node` is resolved
                resolve_layout_impl(node, child);
                node.resolved_size[0] = @max(node.resolved_size[0], node.layout_offset[0] + child.resolved_size[0]);
                node.resolved_size[1] = @max(node.resolved_size[1], @abs(node.layout_offset[1] - child.resolved_size[1]));

                switch (node.layout_axis) {
                    .X => 
                        node.layout_offset[0] += child.resolved_size[0],
                    .Y => 
                        node.layout_offset[1] -= child.resolved_size[1],
                }
            }
            node.resolved_size[0] += ctx.pixels(node.padding[0]);
            node.resolved_size[1] += ctx.pixels(node.padding[1]);

        } else if (node.text.len > 0) {
            node.resolved_size[0] = 2*ctx.pixels(node.padding[0]) + ctx.text_width(node.font_scale, node.text);
            node.resolved_size[1] = 2*ctx.pixels(node.padding[1]) + ctx.cal_font_h(node.font_scale);
        }

    }
};



pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    gpa = gpa_state.allocator();

    UI.key_hash = .{ .init(gpa), .init(gpa) };
    UI.curr_hash = &UI.key_hash[0];
    UI.prev_hash = &UI.key_hash[1];

    UI.ui_arena_state = .{ std.heap.ArenaAllocator.init(gpa), std.heap.ArenaAllocator.init(gpa) };
    

    UI.curr_arena_state = &UI.ui_arena_state[0];
    UI.prev_arena_state = &UI.ui_arena_state[1];
    UI.curr_arena = UI.ui_arena_state[0].allocator();
    UI.prev_arena = UI.ui_arena_state[1].allocator();

    defer { 
        UI.key_hash[0].deinit(); UI.key_hash[1].deinit(); 
        UI.ui_arena_state[0].deinit(); UI.ui_arena_state[1].deinit(); 
    }

    var renderer = Renderer {};

    try RendererContet.init(&ctx, &renderer, Renderer.render, "RSS Reader", 1920, 1024, gpa);
    while (!ctx.window_should_close()) {
        ctx.render();
    }
}
