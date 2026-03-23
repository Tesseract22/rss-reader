const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const log = std.log;

const xml = @import("xml");

const Sqlite = @import("sqlite.zig");
const parser = @import("xml_parser.zig");

const gl = @import("gl");
const Vec2 = gl.Vec2;

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

pub fn v2eq(a: Vec2, b: Vec2) bool {
    return a[0] == b[0] and a[1] == b[1];
}

pub fn v2eq_approx(a: Vec2, b: Vec2) bool {
    return std.math.approxEqAbs(f32, a[0], b[0], 0.0001) and 
    std.math.approxEqAbs(f32, a[1], b[1], 0.0001);
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
    pub const fps_avg_frame_time = 1; // 1 seconds
    pub var frame_time_sum: f32 = 0;
    pub var fps: f32 = 0;

    pub var scissor_stack: std.ArrayList(Box) = .empty;

    pub fn render(_: *RendererContet) void {
        const self = ctx.user_data;
        _ = self;
        UI.resolve_input_event(); 
        UI.render();

        UI.resolve_layout();
        render_ui();
        UI.reset_layout_tree();

        frame_time_sum += ctx.get_delta_time();
        counter += 1;

        var text_buf: [64]u8 = undefined;

        const frame_time_text = std.fmt.bufPrint(&text_buf, "frame time: {d:.5}ms", .{ ctx.get_delta_time() * 1000 }) catch unreachable;
        draw_text(.{ ctx.x_right()-0.25, ctx.y_top()-ctx.cal_font_h(1) },  0.3, frame_time_text, .white);

        if (frame_time_sum >= fps_avg_frame_time) {
            fps = @as(f32, @floatFromInt(counter)) / frame_time_sum;
            frame_time_sum = 0;
            counter = 0;
        }

        const fps_text = std.fmt.bufPrint(&text_buf, "fps: {d:.5}", .{ fps }) catch unreachable;
        draw_text(.{ ctx.x_right()-0.25, ctx.y_top()-ctx.cal_font_h(1)*0.5 },  0.3, fps_text, .white);
        

        // draw_rect(.{ 0, 0 }, .{ 0.2, 0.2 }, .black);
        flush();
    }

    pub fn render_ui() void {
        render_ui_impl(UI.get_root_layout());
        render_ui_hightlight(UI.get_root_layout());
    }

    fn draw_btn_effects(mouse_state: UI.EventSet, box: Box) void {
        if (mouse_state.contains(.Down)) {
            draw_rect(box.botleft, box.size, .from_u32(0x00000030));
        } else if (mouse_state.contains(.Hover)) {
            draw_rect(box.botleft, box.size, .from_u32(0xffffff30));
        }
       if (mouse_state.contains(.Hover) or mouse_state.contains(.Down)) 
            draw_rect_lines(box.botleft, box.size, 2.5, .white);
    }

    fn render_ui_impl(node: *const UI) void {
        const box = node.get_border_box();
        draw_rect(box.botleft, box.size, node.bg_color);


        render_content: {
            if (node.flags.contains(.scissor)) {
                flush();
                if (!push_scissor(box)) break :render_content;
            }

            if (node.flags.contains(.layout)) {
                for (node.children.items) |child| {
                    render_ui_impl(child);
                }
            } else {
                draw_text(v2add(box.botleft, v2pixels(node.padding)), node.font_scale, node.text_content, .white);
            }

            if (node.flags.contains(.scissor)) {
                pop_scissor();
            }
        }

        if (node.flags.contains(.y_scroll) and node.should_enable_scroll()) {
            // Scroll bar background
            draw_rect(.{ box.x_right()-UI.get_scroll_bar_w(), box.botleft[1] }, .{ UI.get_scroll_bar_w(), box.size[1] }, .from_u32(0xefefefff));
            const scroll_bar = node.get_scroll_bar_box();

            // Scroll bar
            draw_rect(
                scroll_bar.botleft,
                scroll_bar.size,
                .from_u32(0x3f3f3fff));
            draw_rect_lines(scroll_bar.botleft, scroll_bar.size, 2.5, node.border_color);
            draw_btn_effects(node.scroll_mouse_event, scroll_bar);
        }
        
        draw_rect_lines(box.botleft, box.size, node.border_width, node.border_color);
        // const outer = node.get_outer_box();
        // draw_rect_lines(outer.botleft, outer.size, node.border_width, .white);
        if (node.flags.contains(.button)) draw_btn_effects(node.mouse_event, box);
    }

    fn render_ui_hightlight(node: *UI) void {
        const box = node.get_border_box();
        if (node.mouse_event.contains(.Focused)) 
            draw_rect_lines(box.botleft, box.size, node.border_width, .yellow);
        if (node.flags.contains(.layout)) {
            for (node.children.items) |child| {
                render_ui_hightlight(child);
            }
        }

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

    // TODO: handle text overflow
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

    // return false if the new scissor does not overlap with the last scissor at all,
    // and thus all drawing can be skipped
    fn push_scissor(box: Box) bool {
        flush();
        const new_scissor = if (scissor_stack.getLastOrNull()) |top|
            top.intersect(box) orelse return false
        else 
            box;

        ctx.begin_scissor_gl_coord(new_scissor.botleft, new_scissor.size);
        scissor_stack.append(UI.curr_arena, new_scissor) catch @panic("OOM");
        return true;
    }

    fn pop_scissor() void {
        flush();
        _ = scissor_stack.pop().?;
        if (scissor_stack.getLastOrNull()) |top| {
            ctx.begin_scissor_gl_coord(top.botleft, top.size);
        } else {
            ctx.end_scissor();
        }
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

    pub fn intersect(a: Box, b: Box) ?Box {
        const botleft = Vec2 {
            @max(a.botleft[0], b.botleft[0]),
            @max(a.botleft[1], b.botleft[1]),
        };
        const topright = Vec2 {
            @min(a.botleft[0] + a.size[0], b.botleft[0] + b.size[0]),
            @min(a.botleft[1] + a.size[1], b.botleft[1] + b.size[1]),

        };

        if (topright[0] <= botleft[0] or topright[1] <= botleft[1]) return null;
        return Box {
            .botleft = botleft,
            .size = v2sub(topright, botleft),
        };
    }
    // return a text_offset that defines the offset from the botleft of the box where text should be drawn
};

fn find_channel_by_id(channel: u32) Sqlite.ChannelWithId {
    for (channels) |ch| {
        if (ch.rowid == channel) return ch;     
    } else return .{ .rowid = std.math.maxInt(u32), .title = "unknown" };
}


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

    pub const EventSet = std.EnumSet(MouseEvent);

    pub var key_hash: [2]std.StringHashMap(*UI) = undefined; // @init_on_main
    pub var curr_hash: *std.StringHashMap(*UI) = undefined; // @init_on_main
    pub var prev_hash: *std.StringHashMap(*UI) = undefined; // @init_on_main

    pub var ui_arena_state: [2]std.heap.ArenaAllocator = undefined; // @init_on_main
    pub var curr_arena_state: *std.heap.ArenaAllocator = undefined; // @init_on_main
    pub var prev_arena_state: *std.heap.ArenaAllocator = undefined; // @init_on_main
    pub var curr_arena: Allocator = undefined; // @init_on_main
    pub var prev_arena: Allocator = undefined; // @init_on_main
    pub var tmp_arena_state: std.heap.ArenaAllocator = undefined; // @init_on_main
    pub var tmp_arena: Allocator = undefined; // @init_on_main

    pub var prev_pixel_scale: f32 = undefined; // @init_on_main
    
                                               
    flags: std.EnumSet(Flag) = .initEmpty(),

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
    target_size: Vec2 = .{ 0, 0 }, 
    resolved_origin: Vec2 = .{ 0, 0 }, // for now, the origin of a box is its topleft corner
    anim_completed: bool = false,

    mouse_event: EventSet = .initEmpty(),
    scroll_mouse_event: EventSet = .initEmpty(),

    // UI logic state
    pub var selected_post_id: []const u8 = "";


    // How to implement focused element:
    //
    // Premise: only one (or zero) focused element at all time
    //
    // 1. Have a global pointer to the focused UI element.
    //    When creating a focusable element, set the pointer to the current element if it is clicked, similar to how
    //    button works (using last frame's data). As such, element deeper in the UI tree should essentially take percedence to its parent.
    //
    // 2. Instead of have a global pointer, put a `is_focused` flag on each element. When a child is focused, it needs to
    //    travel upward to all of its parent and unset all their `is_focused` flag.
    //
    // None of the above method provides accurate information about whether a element is focused DURING build time.
    // 
    // 3. (Current approach) Run a entire event system on previous frame's UI tree. Considering only mouse event, the algo goes as follow:
    //
    // 3a. Start from the root.
    // 3b. Test if the mouse is within the current element. If yes, recurive into the children.
    // 3c. The childrne should return its `is_focused`. If any of the children is focused, the parent should not be marked as focused
    // 3d. Otherwise, mark the current element as focused.
    // 3e. Next frame's UI tree should inherits `is_focused` from the previous frame, and use that during build time.

    const COLOR1 = RGBA.from_u32(0x1b211aff);
    const COLOR2 = RGBA.from_u32(0x547792ff);


    // UI Builder
    pub fn render() void {
        ctx.clear(.from_u32(0x303030ff));
        {
            _ = push_layout(.Y, "outer", .{ .w_strategy = .span_screen, .h_strategy = .span_screen });
            text("Header", .{ .padding = .{ 10, 10 }, .w_strategy = .rest_of_parent });
            {
                _ = push_layout(.X, "main", .{ .w_strategy = .{ .parent_perct = 1 }, .h_strategy = .rest_of_parent });
                const channel_layout = push_scroll_layout("channel_content",
                    .{ .padding = .{ 10, 10 }, .margin = .{ 10, 10 }, .w_strategy = .{ .parent_perct = 0.2 }, .h_strategy = .rest_of_parent });
                _ = channel_layout;
                for (channels) |channel| {
                    _ = text_btn(frame_fmt("{s}#channel", .{ channel.title }),
                        .{ .padding = .{ 10, 10 }, .margin = .{ 4, 4 },
                            .font_scale = 0.5, .w_strategy = .{ .parent_perct = 1.0 }
                        });
                }
                pop_layout();
            }

            {
                const post_layout = push_scroll_layout("post_content", .{ .w_strategy = .{ .parent_perct = 0.8 }, .h_strategy = .{ .parent_perct = 1 } });
                _ = post_layout;
                for (posts) |post| {
                    const selected = std.mem.eql(u8, post.guid, selected_post_id);
                    if (text_btn(frame_fmt("{s}#post_title", .{ post.title }), 
                        .{ 
                            .padding = .{ 10, 20 }, .margin = .{ 10, 0 },
                            .border_color = if (selected) .white else .transparent, .bg_color = if (selected) COLOR2 else .transparent,
                            .font_scale = 0.5, .w_strategy = .{ .parent_perct = 1 },
                            .flags = .initMany(&.{ .scissor }),
                        })) {
                        if (selected) selected_post_id = ""
                        else selected_post_id = post.guid;
                    }

                    if (selected) {
                        const detail_layout = push_layout(.Y, frame_fmt("{s}#detail", .{ post.guid }), .{ 
                            .padding = .{ 10, 10 }, .margin = .{ 10, 0 },
                            .border_color = .white, .bg_color = .transparent,
                            .w_strategy = .{ .parent_perct = 1 }, .h_strategy = .fit_children,
                        });
                        detail_layout.flags.setPresent(.animated, true);
                        detail_layout.flags.setPresent(.scissor, true);

                        text(frame_fmt("By {s}#detail_channel", .{ find_channel_by_id(post.channel).title }), 
                            .{ 
                                .padding = .{ 10, 10 }, .margin = .{ 0, 0 },
                                .border_color = .transparent, .bg_color = .transparent,
                                .font_scale = 0.4,
                                .w_strategy = .{ .parent_perct = 1 }, .h_strategy = .fit_text,
                            });
                        text(frame_fmt("{s}#detail_description", .{ post.description }), 
                            .{ 
                                .padding = .{ 10, 10 }, .margin = .{ 0, 0 },
                                .border_color = .transparent, .bg_color = .transparent,
                                .font_scale = 0.4,
                                .w_strategy = .{ .parent_perct = 1 }, .h_strategy = .fit_text,
                            });
                        _ = text_btn(frame_fmt("{s}#detail_link", .{ post.link }), 
                            .{ 
                                .padding = .{ 10, 10 }, .margin = .{ 0, 0 },
                                .border_color = .transparent, .bg_color = .transparent,
                                .font_scale = 0.4,
                                .w_strategy = .{ .parent_perct = 1 }, .h_strategy = .fit_text,
                            });
                        pop_layout();
                    }
                }
                pop_layout();
            }


            pop_layout();
        }
        prev_pixel_scale = ctx.pixel_scale;
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
        flags: std.EnumSet(Flag) = .initEmpty(),
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
        animated,
        focusable,
    };

    pub const MouseEvent = enum {
        Hover,
        Down,
        Clicked,
        Focused,
    };

    // the result is invalidated the next time tmp_fmt is called
    pub fn tmp_fmt(comptime fmt: []const u8, args: anytype) []const u8 {
        _ = tmp_arena_state.reset(.retain_capacity);
        return std.fmt.allocPrint(tmp_arena, fmt, args) catch @panic("OOM");
    }

    pub fn frame_fmt(comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(curr_arena, fmt, args) catch @panic("OOM");
    }

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
        var box = Box { 
            .botleft = v2add(border.botleft, padding),
            .size = v2sub(border.size, v2scal(padding, 2))
        };
        if (node.flags.contains(.y_scroll) and node.should_enable_scroll()) {
            box.size[0] -= UI.get_scroll_bar_w(); 
        }
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

    pub fn check_non_empty(content: []const u8) []const u8 {
        return if (content.len == 0) "(empty)" else content;
    }

    pub fn cut_text_hash(str_hash: []const u8) []const u8 {
        const hash_index = std.mem.indexOfScalar(u8, str_hash, '#') orelse return str_hash;
        return str_hash[0..hash_index]; 
    }

    pub fn preprocess_text(txt: []const u8) []const u8 {
        return check_non_empty(cut_text_hash(txt));
    }

    pub fn text(content: []const u8, opts: UIOptions) void {
        const ui = new_default();     
        ui.text_content = preprocess_text(content);
        set_opts(ui, opts);
        ui.add_to_layout();
    }

    // FIXME: hacky function
    pub fn handle_mouse(box: Box) EventSet {
        var mouse_state = EventSet.initEmpty();
        const hover = mouse_within_rect(box);
        mouse_state.setPresent(.Hover, hover);
        mouse_state.setPresent(.Clicked, hover and ctx.is_mouse_released(.mouse_left));
        mouse_state.setPresent(.Down, hover and ctx.is_mouse_down(.mouse_left));
        mouse_state.setPresent(.Focused, mouse_state.contains(.Clicked));
        return mouse_state;
    }

    pub fn text_btn(content: []const u8, opts: UIOptions) bool {
        const ui = new_default();     
        set_opts(ui, opts);

        ui.text_content = preprocess_text(content);
        ui.flags.setPresent(.button, true);
        ui.add_to_layout();

        curr_hash.putNoClobber(content, ui) catch unreachable;

        const prev_ui = prev_hash.get(content) orelse return false;
        
        ui.mouse_event = prev_ui.mouse_event;
        return ui.mouse_event.contains(.Clicked);
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
    pub var prev_root_layout: ?*UI = null;
    pub var root_layout: *UI = undefined;

    pub fn push_layout(axis: Axis, str_hash: []const u8, opts: UIOptions) *UI {
        assert(str_hash.len != 0);
        const layout = new_default();
        layout.set_opts(opts);
        layout.flags.setPresent(.layout, true);
        layout.layout_axis = axis;

        if (layouts_stack.items.len == 0) {
            root_layout = layout;
        } else {
            layout.add_to_layout();
        }
        layouts_stack.append(gpa, layout) catch @panic("OOM");

        curr_hash.putNoClobber(str_hash, layout) catch unreachable;
        if (prev_hash.get(str_hash)) |prev_layout| {
            layout.resolved_size = prev_layout.resolved_size; // TODO: handle target_resolved_size
            layout.anim_completed = prev_layout.anim_completed;
        }
        return layout;
    }

    pub fn push_scroll_layout(str_hash: []const u8, opts: UIOptions) *UI {
        const dt = ctx.get_delta_time();
        const scroll_spd = 1;
        const layout = push_layout(.Y, str_hash, opts);
        layout.flags.setPresent(.y_scroll, true);
        layout.flags.setPresent(.scissor, true);
        layout.flags.setPresent(.focusable, true);

        if (prev_hash.get(str_hash)) |prev_layout| {
            layout.scroll_offset = prev_layout.scroll_offset;
            layout.children_bounding_size = prev_layout.children_bounding_size;
            layout.resolved_origin = prev_layout.resolved_origin;
            layout.mouse_event = prev_layout.mouse_event;
            layout.scroll_mouse_event = prev_layout.scroll_mouse_event;
            // layout.resolved_size = prev_layout.resolved_size; // TODO: handle target_resolved_size

            const scroll_h = layout.children_bounding_size[1];
            const display_h = prev_layout.resolved_size[1];
            if (scroll_h > display_h) {
                // TODO: arrow key?
                // handlem mouse scroll
                if (layout.mouse_event.contains(.Focused))
                    layout.scroll_offset -= ctx.mouse_scroll[1] * dt * 30 * scroll_spd / scroll_h;

                // handle dragging scroll bar
                if (layout.scroll_mouse_event.contains(.Down)) {
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

    pub fn get_scroll_bar_h(node: *const UI) f32 {
        const box = Box.from_topleft(node.resolved_origin, node.resolved_size);
        const scroll_h = node.children_bounding_size[1];
        const scroll_bar_h = (box.size[1] / scroll_h) * box.size[1];
        return scroll_bar_h;
    }

    pub fn get_scroll_bar_box(node: *const UI) Box {
        const border = node.get_border_box();
        const scroll_bar_h = node.get_scroll_bar_h();
        const scroll_bar_w = get_scroll_bar_w();
        const scroll_bar = Box {
            .botleft = .{ border.x_right()-scroll_bar_w, border.y_top() - node.scroll_offset*border.size[1]-scroll_bar_h },
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

        prev_root_layout = root_layout;
        root_layout = undefined;

        layouts_stack.clearRetainingCapacity();
    }

    pub fn resolve_layout() void {
        const root = get_root_layout();
        resolve_layout_impl(null, root);
    }

    fn offset_origin_recursive(node: *UI, offset: Vec2) void {
        node.resolved_origin = v2add(node.resolved_origin, offset);
        for (node.children.items) |child|
            offset_origin_recursive(child, offset);
    }

    // TODO: move this into zig2d?
    fn screen_box() Box {
        return .{
            .botleft = .{ ctx.x_left(), ctx.y_bot() },
            .size = .{ ctx.screen_w(), ctx.screen_h() },
        };
    }

    fn resolve_input_event() void {
        _ = resolve_input_event_impl(prev_root_layout orelse return, screen_box());
    }

    fn resolve_input_event_impl(node: *UI, _: Box) bool {
        const is_focused = node.mouse_event.contains(.Focused);
        node.mouse_event = .initEmpty();
        node.mouse_event.setPresent(.Focused, is_focused and !ctx.is_mouse_released(.mouse_left));
        // FIXME: use scissor?
        // const border = node.get_border_box().intersect(parent_border) orelse return;
        const border = node.get_border_box();
        node.mouse_event.setUnion(handle_mouse(border));
        if (!node.flags.contains(.focusable)) node.mouse_event.setPresent(.Focused, false);
        if (node.flags.contains(.y_scroll)) {
            node.scroll_mouse_event = .initEmpty();
            node.scroll_mouse_event.setUnion(handle_mouse(node.get_scroll_bar_box()));
        }
        if (!node.mouse_event.contains(.Hover)) return false;

        // the event of the child can affect that of its parent in one of two ways:
        // 
        // 1. the child trumps the parent, i.e. when child is hovered, parent is not.
        // 2. no effect
        // 3. propagate upwards
        var event_stop = EventSet.initFull();
        event_stop.setPresent(.Focused, false);

        var child_focused = false;
        for (node.children.items) |child| {
            child_focused |= resolve_input_event_impl(child, border);
            node.mouse_event.setIntersection(child.mouse_event.intersectWith(event_stop).complement());
        }
        
        if (child_focused) {
            node.mouse_event.setPresent(.Focused, false);
        }
        return child_focused or node.mouse_event.contains(.Focused);
    }

    fn resolve_size_from_target(node: *UI, axis: Axis) void {
        if (node.flags.contains(.animated) and !node.anim_completed) {
            node.resolved_size[@intFromEnum(axis)] = exp_smooth(node.resolved_size[@intFromEnum(axis)], node.target_size[@intFromEnum(axis)], ctx.get_delta_time());
            if (v2eq_approx(node.resolved_size, node.target_size)) {
                node.anim_completed = true;
            }
        } else {
            node.resolved_size[@intFromEnum(axis)] = node.target_size[@intFromEnum(axis)];
        }
    } 

    // TODO: works with pixel directly
    fn resolve_size_pre_order(maybe_parent: ?*const UI, node: *UI) void {
        if (node.w_strategy.is_pre_order()) {
            switch (node.w_strategy) {
                .fit_text => {
                    node.target_size[0] = 2*ctx.pixels(node.padding[0] + node.margin[0]) + ctx.text_width(node.font_scale, node.text_content);
                },
                .fixed_in_pixels => |p| node.target_size[0] = ctx.pixels(2*(node.padding[0] + node.margin[0]) + p),
                .span_screen => node.target_size[0] = ctx.x_right() - node.resolved_origin[0],

                .parent_perct,
                .rest_of_parent => {
                    const parent = maybe_parent orelse unreachable;
                    const parent_box = parent.get_content_box();
                    switch (node.w_strategy) {
                        .parent_perct => |prect| {
                            assert(parent.w_strategy.is_pre_order());
                            node.target_size[0] = parent_box.size[0] * prect;
                        },
                        .rest_of_parent => {
                            assert(parent.w_strategy.is_pre_order());
                            node.target_size[0] = parent_box.size[0] - parent.layout_offset[0];
                        },
                        else => unreachable,
                    }
                },
                else => |strat| assert(!strat.is_pre_order()),
            }
            resolve_size_from_target(node, .X);
        }

        if (node.h_strategy.is_pre_order()) {
            switch (node.h_strategy) {
                .fit_text => {
                    node.target_size[1] = 2*ctx.pixels(node.padding[1] + node.margin[1]) + ctx.cal_font_h(node.font_scale);
                },
                .fixed_in_pixels => |p| node.target_size[1] = ctx.pixels(2*(node.padding[1] + node.margin[1]) + p),
                .span_screen => node.target_size[1] = node.resolved_origin[1] - ctx.y_bot(),

                .parent_perct,
                .rest_of_parent => {
                    const parent = maybe_parent orelse unreachable;
                    const parent_box = parent.get_content_box();
                    switch (node.h_strategy) {
                        .parent_perct => |prect| {
                            assert(parent.w_strategy.is_pre_order());
                            node.target_size[1] = parent_box.size[1] * prect;
                        },
                        .rest_of_parent => {
                            assert(parent.w_strategy.is_pre_order());
                            node.target_size[1] = parent_box.size[1] + parent.layout_offset[1];
                        },
                        else => unreachable,
                    }

                },
                else => |strat| assert(!strat.is_pre_order()),
            }
            resolve_size_from_target(node, .Y);
        }
    }

    fn resolve_size_post_order(_: ?*const UI, node: *UI) void {
        if (!node.w_strategy.is_pre_order()) {
            switch (node.w_strategy) {
                .fit_children => {
                    node.target_size[0] = node.children_bounding_size[0];
                },
                else => |strat| assert(strat.is_pre_order()),
            }
            resolve_size_from_target(node, .X);
        }
        if (!node.h_strategy.is_pre_order()) {
            switch (node.h_strategy) {
                .fit_children => {
                    node.target_size[1] = node.children_bounding_size[1];
                },
                else => |strat| assert(strat.is_pre_order()),
            }
            resolve_size_from_target(node, .Y);
        }
    }

    // A recursive function to resolve layout
    // The origin of parent must be resolved before called.
    //
    // After this function, both the size and origin are resolved.
    fn resolve_layout_impl(maybe_parent: ?*const UI, node: *UI) void {
        if (maybe_parent) |parent| {
            assert(parent.flags.contains(.layout));
            node.resolved_origin[0] = parent.resolved_origin[0] + parent.layout_offset[0];
            node.resolved_origin[1] = parent.resolved_origin[1] + parent.layout_offset[1];
        } else {
            // topleft corner of the screen
            node.resolved_origin[0] = ctx.x_left();
            node.resolved_origin[1] = ctx.y_top();
        }

        node.resolved_size = v2scal(node.resolved_size, ctx.pixel_scale/prev_pixel_scale);
        resolve_size_pre_order(maybe_parent, node); 
        {
            var largest_child = Vec2 { 0, 0 };  
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
            node.children_bounding_size[0] = @max(largest_child[0], ctx.pixels(node.padding[0] + node.margin[0]) + @abs(node.layout_offset[0]));
            node.children_bounding_size[1] = @max(largest_child[1], ctx.pixels(node.padding[1] + node.margin[1]) + @abs(node.layout_offset[1]));


            for (node.children.items) |child| {
                offset_origin_recursive(child, .{ 0, node.scroll_offset * node.children_bounding_size[1]});
            }
        }
        resolve_size_post_order(maybe_parent, node);
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

    UI.tmp_arena_state = std.heap.ArenaAllocator.init(gpa);
    UI.tmp_arena = UI.tmp_arena_state.allocator();

    
    std.log.debug("init database.", .{});
    rss_db = try Sqlite.init("feed.db");
    defer rss_db.deinit();

    channels = try rss_db.get_channels_all(gpa);
    posts = try rss_db.get_posts_all(gpa);

    defer { 
        UI.key_hash[0].deinit(); UI.key_hash[1].deinit(); 
        UI.ui_arena_state[0].deinit(); UI.ui_arena_state[1].deinit(); 
        UI.tmp_arena_state.deinit();
    }

    var renderer = Renderer {};

    try RendererContet.init(&ctx, &renderer, Renderer.render, "RSS Reader", 1920, 1024, gpa);

    UI.prev_pixel_scale = ctx.pixel_scale;

    while (!ctx.window_should_close()) {
        ctx.render();
    }
}

pub const SMOOTH_SPD = 50;
pub fn exp_smooth(x: f32, target: f32, dt: f32) f32 {
    return x + (target - x) * (1 - @exp(-dt * SMOOTH_SPD));
}
