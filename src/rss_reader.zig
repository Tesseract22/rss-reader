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

pub fn v2add(a: Vec2, b: Vec2) Vec2 {
    return .{ a[0] + b[0], a[1] + b[1] };
}

pub fn v2sub(a: Vec2, b: Vec2) Vec2 {
    return .{ a[0] - b[0], a[1] - b[1] };
}

pub fn v2scal(a: Vec2, b: f32) Vec2 {
    return .{ a[0] * b , a[1] * b };
}

pub fn v2pixels(a: Vec2) Vec2 {
    return .{ ctx.pixels(a[0]), ctx.pixels(a[1]) };
}

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
       
        UI.render();

        UI.resolve_layout();
        render_ui();
        UI.reset_layout_tree();
        // draw_rect(.{ 0, 0 }, .{ 0.2, 0.2 }, .black);
        flush();
        counter  += 1;
    }

    pub fn render_ui() void {
        render_ui_impl(UI.get_root_layout());
    }

    fn draw_btn_overlay(mouse_state: std.EnumSet(UI.MouseState), box: Box) void {
        if (mouse_state.contains(.Down)) {
            draw_rect(box.botleft, box.size, .from_u32(0x00000030));
        } else if (mouse_state.contains(.Hover)) {
            draw_rect(box.botleft, box.size, .from_u32(0xffffff30));
        }
       if (mouse_state.contains(.Hover) or mouse_state.contains(.Down)) 
            draw_rect_lines(box.botleft, box.size, 2.5, .white);
    }

    fn render_ui_impl(node: *UI) void {
        const box = node.get_border_box();
        draw_rect(box.botleft, box.size, node.bg_color);


        if (node.flags.contains(.scissor)) {
            flush();
            ctx.begin_scissor_gl_coord(box.botleft, box.size); // TODO: handle stack of scissors
        }
        
        if (node.flags.contains(.layout)) {
            for (node.children.items) |child| {
                render_ui_impl(child);
            }
        } else {
            draw_text(v2add(box.botleft, v2pixels(node.padding)), node.font_scale, node.text_content, .white);
        }

        if (node.flags.contains(.y_scroll) and node.should_enable_scroll()) {
            // Scroll bar background
            draw_rect(.{ box.x_right()-UI.get_scroll_bar_w(), box.botleft[1] }, .{ UI.get_scroll_bar_w(), box.size[1] }, .from_u32(0xefefefff));
            const scroll_bar = node.get_scroll_bar_box(box);

            // Scroll bar
            draw_rect(
                scroll_bar.botleft,
                scroll_bar.size,
                .from_u32(0x3f3f3fff));
            draw_rect_lines(scroll_bar.botleft, scroll_bar.size, 2.5, node.border_color);
            draw_btn_overlay(node.mouse_state, scroll_bar);
        }

        if (node.flags.contains(.scissor)) {
            flush();
            ctx.end_scissor();
        }
        draw_rect_lines(box.botleft, box.size, node.border_width, node.border_color);
        // const outer = node.get_outer_box();
        // draw_rect_lines(outer.botleft, outer.size, node.border_width, .white);
        if (node.flags.contains(.button)) draw_btn_overlay(node.mouse_state, box);
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
            .{ .tex = .{ .id = ctx.fonts.tex, .w = undefined, .h = undefined }, .border_thickness = null, .shader = ctx.font_shader_pgm }, 0);
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
        // pre-order
        fixed_in_pixels: f32,
        span_screen,
        // parent must also be pre-order
        parent_perct: f32,
        rest_of_parent,
        fit_text,

        // post-order
        fit_children,

        pub fn is_pre_order(self: SizeStrategy) bool {
            switch (self) {
                .fit_children => return false,
                else => return true,
            }
        }
    };

    pub var key_hash: [2]std.StringHashMap(*UI) = undefined; // @init_on_main
    pub var curr_hash: *std.StringHashMap(*UI) = undefined; // @init_on_main
    pub var prev_hash: *std.StringHashMap(*UI) = undefined; // @init_on_main

    pub var ui_arena_state: [2]std.heap.ArenaAllocator = undefined; // @init_on_main
    pub var curr_arena_state: *std.heap.ArenaAllocator = undefined; // @init_on_main
    pub var prev_arena_state: *std.heap.ArenaAllocator = undefined; // @init_on_main
    pub var curr_arena: Allocator = undefined; // @init_on_main
    pub var prev_arena: Allocator = undefined; // @init_on_main
                                               
    pub var font: gl.Font.Dynamic = undefined; // @init_on_main

    flags: std.EnumSet(Flag) = std.EnumSet(Flag).initEmpty(),

    children: std.ArrayList(*UI) = .empty,
    text_content: []const u8 = "",
    font_scale: f32 = 1,
    bg_color: RGBA = COLOR1,
    border_color: RGBA = COLOR2,
    border_width: f32 = 2,
    padding: Vec2 = .{ 0, 0 },
    margin: Vec2 = .{ 0, 0 },

    w_strategy: SizeStrategy = .fit_text,
    h_strategy: SizeStrategy = .fit_text,

    // resolve time fiels
    scroll_offset: f32 = 0,

    layout_offset: Vec2 = .{ 0, 0 },
    layout_axis: Axis = .X,
    children_bounding_size: Vec2 = .{ 0, 0 },
    resolved_size: Vec2 = .{ 0, 0 }, // this includes padding and margin
    resolved_origin: Vec2 = .{ 0, 0 }, // for now, the origin of a box is its topleft corner

    mouse_state: std.EnumSet(MouseState) = .initEmpty(),

    const COLOR1 = RGBA.from_u32(0x1b211aff);
    const COLOR2 = RGBA.from_u32(0x547792ff);

    pub fn render() void {
        ctx.clear(.from_u32(0x303030ff));
        {
            _ = push_layout(.Y, .{ .w_strategy = .span_screen, .h_strategy = .span_screen });
            text("Header", .{ .padding = .{ 10, 10 }, .w_strategy = .rest_of_parent });
            {
                _ = push_layout(.X, .{ .w_strategy = .{ .parent_perct = 1 }, .h_strategy = .rest_of_parent });
                const channel_layout = push_scroll_layout("channel_content",
                    .{ .padding = .{ 10, 10 }, .margin = .{ 10, 10 }, .w_strategy = .{ .parent_perct = 0.2 }, .h_strategy = .rest_of_parent });
                _ = channel_layout;
                for (channels) |channel| {
                    _ = text_btn(channel.title,
                        .{ .padding = .{ 10, 10 }, .margin = .{ 4, 4 },
                            .font_scale = 0.5, .w_strategy = .{ .parent_perct = 1.0 }
                        });
                }
                _ = text_btn("xx",
                    .{ .padding = .{ 10, 10 }, .margin = .{ 4, 4 },
                        .font_scale = 0.5, .w_strategy = .{ .parent_perct = 1.0 }
                    });
                pop_layout();
            }

            {
                const post_layout = push_scroll_layout("post_content", .{ .w_strategy = .{ .parent_perct = 0.8 }, .h_strategy = .{ .parent_perct = 1 } });
                _ = post_layout;
                for (posts) |post|
                    _ = text_btn(post.title, 
                        .{ 
                            .padding = .{ 10, 10 }, .margin = .{ 4, 4 },
                            .border_color = .transparent, .bg_color = .transparent,
                            .font_scale = 0.5, .w_strategy = .{ .parent_perct = 1 },
                        });
                pop_layout();
            }


            pop_layout();
        }
    }

    const UIOptions = struct {
        font_scale: f32 = 1,
        bg_color: RGBA = COLOR1,
        border_color: RGBA = COLOR2,
        border_width: f32 = 2,
        padding: Vec2 = .{ 0, 0 },
        margin: Vec2 = .{ 0, 0 },
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
        button,
    };

    pub const MouseState = enum {
        Hover,
        Down,
        Clicked,
    };

    pub fn get_outer_box(node: *const UI) Box {
        return Box.from_topleft(node.resolved_origin, node.resolved_size);
    }

    pub fn get_border_box(node: *const UI) Box {
        const box_with_margin = node.get_outer_box();
        const margin_pixels = v2pixels(node.margin);
        const box = Box { 
            .botleft = v2add(box_with_margin.botleft, margin_pixels),
            .size = v2sub(box_with_margin.size, v2scal(margin_pixels, 2))
        };
        return box;
    }

    pub fn get_content_box(node: *const UI) Box {
        const border = node.get_border_box();
        const padding = v2pixels(node.padding);
        const box = Box { 
            .botleft = v2add(border.botleft, padding),
            .size = v2sub(border.size, v2scal(padding, 2))
        };
        return box;
    }

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
        const struct_info = @typeInfo(UIOptions).@"struct";
        inline for (struct_info.fields) |field| {
           @field(ui, field.name) = @field(opts, field.name);
        }
    }

    pub fn text(content: []const u8, opts: UIOptions) void {
        const ui = new_default();     
        ui.text_content = content;
        set_opts(ui, opts);
        ui.add_to_layout();
    }

    pub fn handle_btn(box: Box) std.EnumSet(MouseState) {
        var mouse_state = std.EnumSet(MouseState).initEmpty();
        const hover = mouse_within_rect(box);
        mouse_state.setPresent(.Hover, hover);
        mouse_state.setPresent(.Clicked, hover and ctx.mouse_left);
        mouse_state.setPresent(.Down, hover and c.RGFW_isMouseDown(c.RGFW_mouseLeft) == 1);
        return mouse_state;
    }

    // better hashing strategies
    pub fn text_btn(content: []const u8, opts: UIOptions) bool {
        const ui = new_default();     

        ui.text_content = content;
        ui.flags.setPresent(.button, true);
        set_opts(ui, opts);
        ui.add_to_layout();

        curr_hash.putNoClobber(content, ui) catch unreachable;

        const prev_ui = prev_hash.get(content) orelse return false;
        
        ui.mouse_state = handle_btn(.from_topleft(prev_ui.resolved_origin, prev_ui.resolved_size));
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

    pub fn push_layout(axis: Axis, opts: UIOptions) *UI {
        const new_layout = new_default();
        new_layout.flags.setPresent(.layout, true);
        new_layout.layout_axis = axis;
        new_layout.set_opts(opts);

        if (layouts_stack.items.len == 0) {
            root_layout = new_layout;
        } else {
            new_layout.add_to_layout();
        }
        layouts_stack.append(gpa, new_layout) catch @panic("OOM");
        return new_layout;
    }

    pub fn push_scroll_layout(str_hash: []const u8, opts: UIOptions) *UI {
        const dt = ctx.get_delta_time();
        const scroll_spd = 1;
        const layout = push_layout(.Y, opts);
        layout.flags.setPresent(.y_scroll, true);
        layout.flags.setPresent(.scissor, true);

        curr_hash.putNoClobber(str_hash, layout) catch unreachable;

        if (prev_hash.get(str_hash)) |prev_layout| {
            layout.scroll_offset = prev_layout.scroll_offset;
            layout.children_bounding_size = prev_layout.children_bounding_size;
            layout.resolved_origin = prev_layout.resolved_origin;
            layout.resolved_size = prev_layout.resolved_size;

            const scroll_h = layout.children_bounding_size[1];
            const display_h = prev_layout.resolved_size[1];
            if (scroll_h > display_h) {
                // TODO: arrow key?
                // TODO: only do this when focused
                // handlem mouse scroll
                layout.scroll_offset -= ctx.mouse_scroll[1] * dt * 30 * scroll_spd / scroll_h;

                // handle dragging scroll bar
                const box = Box.from_topleft(prev_layout.resolved_origin, prev_layout.resolved_size);
                const scroll_bar = layout.get_scroll_bar_box(box);
                layout.mouse_state = handle_btn(scroll_bar);
                if (prev_layout.mouse_state.contains(.Down)){
                    if (mouse_within_rect(box) and c.RGFW_isMouseDown(c.RGFW_mouseLeft) == 1) {
                        layout.mouse_state.setPresent(.Down, true);
                    }
                }
                if (layout.mouse_state.contains(.Down)) {
                    layout.scroll_offset += ctx.mouse_delta[1]/display_h; 
                }

                // clamp everything
                layout.scroll_offset = std.math.clamp(layout.scroll_offset, 0, (scroll_h-display_h)/scroll_h);
            }
        }
        
        return layout;
    }

    pub fn get_scroll_bar_w() f32 {
        return  @max(0.02, ctx.pixels(20));
    }

    pub fn get_scroll_bar_h(node: *UI) f32 {
        const box = Box.from_topleft(node.resolved_origin, node.resolved_size);
        const scroll_h = node.children_bounding_size[1];
        const scroll_bar_h = (box.size[1] / scroll_h) * box.size[1];
        return scroll_bar_h;
    }

    pub fn get_scroll_bar_box(node: *UI, box: Box) Box {
        const scroll_bar_h = node.get_scroll_bar_h();
        const scroll_bar_w = get_scroll_bar_w();
        const scroll_bar = Box {
            .botleft = .{ box.x_right()-scroll_bar_w, box.y_top() - node.scroll_offset*box.size[1]-scroll_bar_h },
            .size =.{ scroll_bar_w, scroll_bar_h },
        };
        return scroll_bar;
    }

    pub fn should_enable_scroll(layout: UI) bool {
        const scroll_h = layout.children_bounding_size[1];
        const display_h = layout.resolved_size[1];
        return scroll_h > display_h;
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

    pub fn reset_layout_tree() void {
        prev_hash.clearRetainingCapacity();
        std.mem.swap(std.StringHashMap(*UI), prev_hash, curr_hash);

        _ = prev_arena_state.reset(.retain_capacity);
        std.mem.swap(std.heap.ArenaAllocator, prev_arena_state, curr_arena_state);
        curr_arena = curr_arena_state.allocator();
        prev_arena = prev_arena_state.allocator();

        layouts_stack.clearRetainingCapacity();
    }

    pub fn resolve_layout() void {
        const root = get_root_layout();
        resolve_layout_impl(null, root);
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
            // if (parent.scroll_offset > 0) 
            //     log.debug("offset: {} {}", .{ parent.scroll_offset * parent.children_bounding_size[1], parent.children_bounding_size[1] });
        } else {
            // topleft corner of the screen
            node.resolved_origin[0] = ctx.x_left();
            node.resolved_origin[1] = ctx.y_top();
        }

        
        switch (node.w_strategy) {
            .fit_text => {
                node.resolved_size[0] = 2*ctx.pixels(node.padding[0] + node.margin[0]) + ctx.text_width(node.font_scale, node.text_content);
            },
            .fixed_in_pixels => |p| node.resolved_size[0] = ctx.pixels(2*(node.padding[0] + node.margin[0]) + p),
            .span_screen => node.resolved_size[0] = ctx.x_right() - node.resolved_origin[0],

            .parent_perct,
            .rest_of_parent => {
                const parent = maybe_parent orelse unreachable;
                const parent_box = parent.get_content_box();
                switch (node.w_strategy) {
                    .parent_perct => |prect| {
                        assert(parent.w_strategy.is_pre_order());
                        node.resolved_size[0] = parent_box.size[0] * prect;
                    },
                    .rest_of_parent => {
                        assert(parent.w_strategy.is_pre_order());
                        node.resolved_size[0] = parent_box.size[0] - parent.layout_offset[0];
                    },
                    else => unreachable,
                }
            },
            else => |strat| assert(!strat.is_pre_order()),
        }

        switch (node.h_strategy) {
            .fit_text => {
                node.resolved_size[1] = 2*ctx.pixels(node.padding[1] + node.margin[1]) + ctx.cal_font_h(node.font_scale);
            },
            .fixed_in_pixels => |p| node.resolved_size[1] = ctx.pixels(2*(node.padding[1] + node.margin[1]) + p),
            .span_screen => node.resolved_size[1] = node.resolved_origin[1] - ctx.y_bot(),

            .parent_perct,
            .rest_of_parent => {
                const parent = maybe_parent orelse unreachable;
                const parent_box = parent.get_content_box();
                switch (node.h_strategy) {
                    .parent_perct => |prect| {
                        assert(parent.w_strategy.is_pre_order());
                        node.resolved_size[1] = parent_box.size[1] * prect;
                    },
                    .rest_of_parent => {
                        assert(parent.w_strategy.is_pre_order());
                        node.resolved_size[1] = parent_box.size[1] + parent.layout_offset[1];
                    },
                    else => unreachable,
                }

            },
            else => |strat| assert(!strat.is_pre_order()),
        }
        
        var largest_child = Vec2 { 0, 0 };  
        if (node.flags.contains(.layout)) {
            node.layout_offset[0] += ctx.pixels(node.padding[0] + node.margin[0]);
            node.layout_offset[1] -= ctx.pixels(node.padding[1] + node.margin[1]);
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
        node.children_bounding_size[0] = @max(largest_child[0], ctx.pixels(node.padding[0] + node.margin[0]) + @abs(node.layout_offset[0]));
        node.children_bounding_size[1] = @max(largest_child[1], ctx.pixels(node.padding[1] + node.margin[1]) + @abs(node.layout_offset[1]));

        

        switch (node.w_strategy) {
            .fit_children => {
                node.resolved_size[0] = node.children_bounding_size[0];
            },
            else => |strat| assert(strat.is_pre_order()),
        }

        switch (node.h_strategy) {
            .fit_children => {
                node.resolved_size[1] = node.children_bounding_size[1];
            },
            else => |strat| assert(strat.is_pre_order()),
        }
        if (node.scroll_offset > 0) 
            log.debug("perct: {}", .{ node.children_bounding_size[1] / ctx.pixel_scale });

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
