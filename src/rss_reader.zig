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
            _ = UI.push_layout(.Y);
            UI.text("Header", .{ .w_strategy = .span_screen });
            _ = UI.push_layout(.X);
            {
                _ = UI.push_layout(.Y);
                for (channels) |channel| {
                    _ = UI.text_btn(channel.title, .{ .font_scale = 0.5, .w_strategy = .{ .fixed_in_pixels = 300 } });
                }
                UI.pop_layout();
            }

            {
                _ = UI.push_scroll_layout("post_content", .span_screen);
                for (posts) |post|
                    _ = UI.text_btn(post.title, . { .font_scale = 0.5, .w_strategy = .span_screen });
                UI.pop_layout();
            }

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


        if (node.flags.contains(.scissor)) {
            flush();
            ctx.begin_scissor_gl_coord(box.botleft, box.size); // TODO: handle stack of scissors
        }
        
        if (node.flags.contains(.layout)) {
            for (node.children.items) |child| {
                render_ui_impl(child);
            }
        } else {
            draw_text(.{ box.botleft[0]+ctx.pixels(node.padding[0]), box.botleft[1]+ctx.pixels(node.padding[1]) }, node.font_scale, node.text_content, .white);
        }

        if (node.flags.contains(.y_scroll)) {
            const scroll_bar_w = @max(0.02, ctx.pixels(20));
            const scroll_h = node.children_bounding_size[1];
            const scroll_bar_h = (box.size[1] / scroll_h) * box.size[1];
            // Scroll bar background
            draw_rect(.{ box.x_right()-scroll_bar_w, box.botleft[1] }, .{ scroll_bar_w, box.size[1] }, .from_u32(0x7f7f7fdf));
            const scroll_bar = Box {
                .botleft = .{ box.x_right()-scroll_bar_w, box.y_top() - node.scroll_offset*box.size[1]-scroll_bar_h },
                .size =.{ scroll_bar_w, scroll_bar_h },
            };

            draw_rect(
                scroll_bar.botleft,
                scroll_bar.size,
                .from_u32(0x3f3f3fff));

        }

        if (node.flags.contains(.scissor)) {
            flush();
            ctx.end_scissor();
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
    pub const SizeStrategy = union(enum) {
        fit_text,
        fit_children,
        fixed_in_pixels: f32,
        span_screen,
    };

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
    text_content: []const u8 = "",
    font_scale: f32 = 1,
    bg_color: RGBA = .transparent,
    border_color: RGBA = .from_u32(0x7f7f7fff),
    padding: Vec2 = .{ 10, 10 },
    w_strategy: SizeStrategy = .fit_text,
    h_strategy: SizeStrategy = .fit_text,

    // resolve time fiels
    scroll_offset: f32 = 0,

    layout_offset: Vec2 = .{ 0, 0 },
    layout_axis: Axis = .X,
    children_bounding_size: Vec2 = .{ 0, 0 },
    resolved_size: Vec2 = .{ 0, 0 },
    resolved_origin: Vec2 = .{ 0, 0 }, // for now, the origin of a box is its topleft corner

    mouse_state: std.EnumSet(MouseState) = .initEmpty(),

    const UIOptions = struct {
        font_scale: f32 = 1,
        bg_color: RGBA = .transparent,
        border_color: RGBA = .from_u32(0x7f7f7fff),
        padding: Vec2 = .{ 10, 10 },
        w_strategy: SizeStrategy = .fit_text,
        h_strategy: SizeStrategy = .fit_text,
    };

    pub const Axis = enum(u8) {
        X = 0,
        Y = 1,
    };

    pub const Flag = enum {
        layout,
        y_scroll,
        scissor,
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

    fn set_opts(ui: *UI, opts: UIOptions) void {
        ui.font_scale = opts.font_scale;
        ui.bg_color = opts.bg_color;
        ui.border_color = opts.border_color;
        ui.padding = opts.padding;
        ui.w_strategy = opts.w_strategy;
        ui.h_strategy = opts.h_strategy;

    }

    pub fn text(content: []const u8, opts: UIOptions) void {
        const ui = new_default();     
        ui.text_content = content;
        set_opts(ui, opts);
        ui.add_to_layout();
    }

    // better hashing strategies
    pub fn text_btn(content: []const u8, opts: UIOptions) bool {
        const ui = new_default();     

        ui.text_content = content;
        set_opts(ui, opts);
        ui.add_to_layout();

        curr_hash.putNoClobber(content, ui) catch unreachable;

        const prev_ui = prev_hash.get(content) orelse return false;
        
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

    pub fn push_layout(axis: Axis) *UI {
        const new_layout = new_default();
        new_layout.flags.setPresent(.layout, true);
        new_layout.layout_axis = axis;
        new_layout.w_strategy = .fit_children;
        new_layout.h_strategy = .fit_children;
        new_layout.padding = .{ 0, 0 };
        // new_layout.border_color = .transparent;

        if (layouts_stack.items.len == 0) {
            root_layout = new_layout;
        } else {
            new_layout.add_to_layout();
        }
        layouts_stack.append(gpa, new_layout) catch @panic("OOM");
        return new_layout;
    }

    pub fn push_scroll_layout(str_hash: []const u8, h_strategy: SizeStrategy) *UI {
        const dt = ctx.get_delta_time();
        const scroll_spd = 1;
        const new_layout = push_layout(.Y);
        new_layout.flags.setPresent(.y_scroll, true);
        new_layout.flags.setPresent(.scissor, true);
        new_layout.h_strategy = h_strategy;

        curr_hash.putNoClobber(str_hash, new_layout) catch unreachable;

        if (prev_hash.get(str_hash)) |prev_layout| {
            new_layout.scroll_offset = prev_layout.scroll_offset;
            new_layout.children_bounding_size = prev_layout.children_bounding_size;
            new_layout.resolved_size = prev_layout.resolved_size;

            const scroll_h = new_layout.children_bounding_size[1];
            const display_h = new_layout.resolved_size[1];
            if (scroll_h > display_h) {
                new_layout.scroll_offset -= ctx.mouse_scroll[1] * dt * 30 * scroll_spd / scroll_h;
                new_layout.scroll_offset = std.math.clamp(new_layout.scroll_offset, 0, (scroll_h-display_h)/scroll_h);
            }
        }
        
        return new_layout;
    }

    pub fn pop_layout() void {
        _ = layouts_stack.pop().?;
    }

    fn get_curr_layout() *UI {
        const layout = layouts_stack.getLast();
        assert(layout.flags.contains(.layout));

        return layout;
    }

    fn get_root_layout() *UI {
        assert(root_layout.flags.contains(.layout));
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
            assert(parent.flags.contains(.layout));
            node.resolved_origin[0] = parent.resolved_origin[0] + parent.layout_offset[0];
            node.resolved_origin[1] = parent.resolved_origin[1] + parent.layout_offset[1] + parent.scroll_offset * parent.children_bounding_size[1];
        } else {
            // topleft corner of the screen
            node.resolved_origin[0] = ctx.x_left();
            node.resolved_origin[1] = ctx.y_top();
        }

        var largest_child = Vec2 { 0, 0 };  
        if (node.flags.contains(.layout)) {
            node.layout_offset[0] += ctx.pixels(node.padding[0]);
            node.layout_offset[1] -= ctx.pixels(node.padding[1]);
            for (node.children.items) |child| {
                // before recurring into this function, make sure the origin of `node` is resolved
                resolve_layout_impl(node, child);

                switch (node.layout_axis) {
                    .X => 
                        node.layout_offset[0] += child.resolved_size[0],
                    .Y => 
                        node.layout_offset[1] -= child.resolved_size[1],
                }
                for (0..2) |i|
                    largest_child[i] = @max(largest_child[i], child.resolved_size[i]);
            }
        }
        node.children_bounding_size[0] = @max(largest_child[0], ctx.pixels(node.padding[0]) + @abs(node.layout_offset[0]));
        node.children_bounding_size[1] = @max(largest_child[1], ctx.pixels(node.padding[1]) + @abs(node.layout_offset[1]));

        switch (node.w_strategy) {
            .fit_children => {
                node.resolved_size[0] = node.children_bounding_size[0];
            },
            .fit_text => {
                node.resolved_size[0] = 2*ctx.pixels(node.padding[0]) + ctx.text_width(node.font_scale, node.text_content);
            },
            .fixed_in_pixels => |p| node.resolved_size[0] = ctx.pixels(2*node.padding[0] + p),
            .span_screen => node.resolved_size[0] = ctx.x_right() - node.resolved_origin[0],
        }

        switch (node.h_strategy) {
            .fit_children => {
                node.resolved_size[1] = node.children_bounding_size[1];
            },
            .fit_text => {
                node.resolved_size[1] = 2*ctx.pixels(node.padding[1]) + ctx.cal_font_h(node.font_scale);
            },
            .fixed_in_pixels => |p| node.resolved_size[1] = ctx.pixels(2*node.padding[1] + p),
            .span_screen => node.resolved_size[1] = node.resolved_origin[1] - ctx.y_bot(),
        }
    }
};

var rss_db: Sqlite = undefined; // @init_on_main
var channels: []Sqlite.ChannelWithId = undefined; // @init_on_main
var posts: []Sqlite.ItemWithChannel = undefined; // @init_on_main

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

    std.log.debug("init database.", .{});
    rss_db = try Sqlite.init("feed.db");
    defer rss_db.deinit();

    channels = try rss_db.get_channels_all(gpa);
    posts = try rss_db.get_posts_all(gpa);

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
