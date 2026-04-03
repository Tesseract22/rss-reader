const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const log = std.log;

const xml = @import("xml");

const DB = @import("sqlite.zig");
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

pub fn v2splat(f: f32) Vec2 {
    return .{ f, f };
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
    pub var print_debug = false;

    pub fn render(_: *gl.Context) void {
        UI.resolve_input_event(); 
        UI.render();
        const num_of_ui = count_ui(UI.get_root_layout());

        UI.resolve_layout();
        render_ui();
        UI.reset_layout_tree();

        frame_time_sum += ctx.get_delta_time();
        counter += 1;
        if (frame_time_sum >= fps_avg_frame_time) {
            fps = @as(f32, @floatFromInt(counter)) / frame_time_sum;
            frame_time_sum = 0;
            counter = 0;
        }
        if (ctx.is_key_released(.F12)) print_debug = !print_debug;
        if (print_debug) {

            var text_buf: [64]u8 = undefined;
            const debug_font = 0.3;
            const x = ctx.x_right() - ctx.text_width_ascii(debug_font, " ") * text_buf.len;
            {
                const text = std.fmt.bufPrint(&text_buf, "frame time: {d:.5}ms", .{ ctx.get_delta_time() * 1000 }) catch unreachable;
                draw_text(.{ x, ctx.y_top()-ctx.cal_font_h(debug_font) }, debug_font, text, UI.TEXT_COLOR);
            }

            {
                const text = std.fmt.bufPrint(&text_buf, "fps: {d:.5}", .{ fps }) catch unreachable;
                draw_text(.{ x, ctx.y_top()-ctx.cal_font_h(debug_font)*2 }, debug_font, text, .white);
            }

            { 
                const text = std.fmt.bufPrint(&text_buf, "# of UI widget: {}, memory usage of UI widget: {}KB", .{ num_of_ui, num_of_ui * @sizeOf(UI) / 1024 }) catch unreachable;
                draw_text(.{ x, ctx.y_top()-ctx.cal_font_h(debug_font)*3 },  debug_font, text, .white);
            }
        }

        // draw_rect(.{ 0, 0 }, .{ 0.2, 0.2 }, .black);
        flush();
    }

    pub fn render_ui() void {
        ctx.set_mouse_standard(UI.mouse_icon);
        assert(scissor_stack.items.len == 0);
        scissor_stack.clearRetainingCapacity();

        render_ui_impl(UI.get_root_layout());
    }

    fn count_ui(node: *UI) u32 {
        var ct: u32 = 1;
        for (node.children.items) |child| {
            ct += count_ui(child);
        }
        return ct;
    }

    fn draw_btn_effects(mouse_state: UI.EventSet, box: Box) void {
        const border_radius_pixels = ctx.pixels(UI.BORDER_RADIUS);
        if (mouse_state.contains(.Down)) {
            draw_rect(box.botleft, box.size, border_radius_pixels, .from_u32(0x00000030));
        } else if (mouse_state.contains(.Hover)) {
            draw_rect(box.botleft, box.size, border_radius_pixels, .from_u32(0xffffff30));
        }
       if (mouse_state.contains(.Hover) or mouse_state.contains(.Down)) 
            draw_rect_lines(box.botleft, box.size, border_radius_pixels, UI.BORDER_THICKNESS, .white);
    }

    fn render_ui_impl(node: *const UI) void {
        const box = node.get_border_box();
        const border_radius_pixels = ctx.pixels(node.border_radius);
        draw_rect(box.botleft, box.size, border_radius_pixels, node.bg_color);
        draw_rect_lines(box.botleft, box.size, border_radius_pixels, node.border_width, node.border_color);


        blk: {
            const scissor_area = if (node.flags.contains(.scissor))
                push_scissor(box) else UI.screen_box();
            defer if (node.flags.contains(.scissor))
                pop_scissor();
            if (v2eq(scissor_area.size, .{ 0, 0 })) break :blk;

            if (node.flags.contains(.layout)) {
                for (node.children.items) |child| {
                    if (!child.flags.contains(.absolute)) render_ui_impl(child);
                }
            }

            const content = node.get_content_box();
            // if (node.flags.contains(.highlight_text) and std.mem.startsWith(u21, node.text_content, UI.post_search_str)) {
            //     draw_rect(content.botleft, .{ ctx.text_width(node.font_scale, UI.post_search_str), ctx.cal_font_h(node.font_scale) }, UI.COLOR2);
            // }
            // TODO: case insensitive
            switch (node.text_content) {
                .ascii => |bytes|
                    draw_text(content.botleft, node.font_scale, bytes, .white),
                .utf8 => |codepoints|
                    draw_text_codepoints(content.botleft, node.font_scale, codepoints, .white),
            }
        }

        if (node.flags.contains(.input_box)) {
            const tw = switch (node.text_content) {
                .ascii => |bytes| ctx.text_width_ascii(node.font_scale, bytes[0..node.input.cursor]),
                .utf8 => |codepoint| ctx.text_width_codepoints(node.font_scale, codepoint[0..node.input.cursor]),
            };
            const content_box = node.get_content_box();
            const end_of_text = content_box.botleft[0] + tw;
            const cursor_box = Box.from_centerleft(
                .{ end_of_text, content_box.botleft[1] + content_box.size[1]/2 },
                .{ ctx.pixels(3), content_box.size[1] * 0.9 });
            if (node.events.contains(.Focused)) draw_rect(cursor_box.botleft, cursor_box.size, border_radius_pixels, .from_u32(0x7f7f7fff));

        }
        if (node.flags.contains(.y_scroll) and node.should_enable_scroll()) {
            // Scroll bar background
            draw_rect(.{ box.x_right()-UI.get_scroll_bar_w(), box.botleft[1] }, .{ UI.get_scroll_bar_w(), box.size[1] }, border_radius_pixels, UI.TEXT_COLOR );
            const scroll_bar = node.get_scroll_bar_box();

            // Scroll bar
            draw_rect(
                scroll_bar.botleft,
                scroll_bar.size,
                border_radius_pixels,
                UI.COLOR1);
            draw_rect_lines(scroll_bar.botleft, scroll_bar.size, border_radius_pixels, node.border_width, node.border_color);
            draw_btn_effects(node.scroll_mouse_event, scroll_bar);
        }
        if (node.flags.contains(.disabled)) {
            draw_rect(box.botleft, box.size, border_radius_pixels, .from_u32(0xffffff7f));
        }

        if (node.flags.contains(.layout)) {
            for (node.children.items) |child| {
                if (child.flags.contains(.absolute)) render_ui_impl(child);
            }
        }
        // const outer = node.get_outer_box();
        // draw_rect_lines(outer.botleft, outer.size, node.border_width, .white);
        if (node.flags.contains(.button)) draw_btn_effects(node.events, box);
        if (node.events.contains(.Focused))
            draw_rect_lines(box.botleft, box.size, border_radius_pixels, node.border_width, node.focus_border_color);
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

    fn draw_rect(botleft: Vec2, size: Vec2, radius: f32, rgba: RGBA) void {
        if (radius > 0) {
            // TODO: optimize this
            flush();
            ctx.draw_rect_rounded(botleft, size, radius, rgba);
        } else {
            switch_or_append_state(
                .{ .tex = ctx.white_tex, .border_thickness = null, .shader = ctx.base_shader_pgm }, 1); 
            batches.append(gpa, ctx.make_rect_vertex_data(botleft, size, rgba)) catch unreachable;
        }
    }

    fn draw_rect_lines(botleft: Vec2, size: Vec2, radius: f32, thickness: f32, rgba: RGBA) void {
        if (radius > 0) {
            // TODO: optimize this
            flush();
            ctx.draw_rect_rounded_lines(botleft, size, radius, thickness, rgba);
        } else {
            const border2 = Vec2 { ctx.pixels(thickness), ctx.pixels(thickness) };
            switch_or_append_state(
                .{ .tex = ctx.white_tex, .border_thickness = thickness, .shader = ctx.base_shader_pgm }, 1); 
            batches.append(gpa, ctx.make_rect_vertex_data(v2add(botleft, border2), v2sub(size, v2scal(border2, 1)), rgba)) catch unreachable;
        }
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

    fn draw_text_codepoints(pos: Vec2, font_scale: f32, codepoints: []const u21, rgba: RGBA) void {
        switch_or_append_state(
            .{ .tex = .{ .id = ctx.fonts.tex, .w = undefined, .h = undefined }, .border_thickness = null, .shader = ctx.font_shader_pgm }, 0);
        var it = ctx.make_code_point_vertex_data_from_codepoints(pos, font_scale, codepoints, 1024*1024, rgba);
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
    fn push_scissor(box: Box) Box {
        flush();
        const new_scissor = if (scissor_stack.getLastOrNull()) |top|
            top.intersect(box) orelse Box { .botleft = .{ 0, 0 }, .size = .{ 0, 0 } }
        else 
            box;

        ctx.begin_scissor_gl_coord(new_scissor.botleft, new_scissor.size);
        scissor_stack.append(gpa, new_scissor) catch @panic("OOM");
        return box;
    }

    fn pop_scissor() void {
        flush();
        _ = scissor_stack.pop();
        if (scissor_stack.getLastOrNull()) |top| {
            ctx.begin_scissor_gl_coord(top.botleft, top.size);
        } else {
            ctx.end_scissor();
        }
    }
};

pub var gpa: Allocator = undefined; // @init_on_main
pub var ctx: gl.Context = undefined; // @init_on_main

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

fn find_channel_by_id(channel: u32) DB.ChannelWithId {
    for (channels) |ch| {
        if (ch.rowid == channel) return ch;     
    } else return .{ .rowid = std.math.maxInt(u32), .title = "unknown" };
}


// TODO: implement the following functionalities:
// [ ] Mark a post as read.
// [*] Add new channel
// [ ] Filter post
//   * By channel
//   * By title
//   * By already read or not
//

// TODO: ability to focus a UI element on creation
pub const UI = struct {
    pub const SizeStrategy = union(enum) {
        // pre-order
        fixed_in_pixels: f32,
        fixed_in_normalized: f32,
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

    //
    // Input events
    //
    pub var input_chars: std.ArrayList(u21) = .empty;
    pub var backspace: u32 = 0;
    pub var is_paste = false;

    pub var prev_pixel_scale: f32 = undefined; // @init_on_main
  
    pub var force_focus_on: []const u8 = "";

    pub var mouse_icon = gl.Context.MouseIcon.mouse_normal;

    pub const TextContent = union(enum) {
        ascii: []const u8,
        utf8: []const u21,

        pub fn width(self: TextContent, scale: f32, range: [2]u32) f32 {
            return switch (self) {
                .ascii => |bytes| ctx.text_width_ascii(scale, bytes[range[0]..range[1]]),
                .utf8 => |codepoint| ctx.text_width_codepoints(scale, codepoint[range[0]..range[1]]),
            };
        }

        pub fn len(self: TextContent) u32 {
            return @intCast(switch (self) {
                .ascii => |bytes| bytes.len,
                .utf8 => |codepoint| codepoint.len,
            });

        }
    };
               
    str_hash: []const u8 = "",
    flags: std.EnumSet(Flag) = .initEmpty(),

    children: std.ArrayList(*UI) = .empty,
    text_content: TextContent = .{ .ascii = "" },
    font_scale: f32 = 1,
    bg_color: RGBA = COLOR1,
    border_color: RGBA = COLOR2,
    focus_border_color: RGBA = COLOR4,
    border_width: f32 = UI.BORDER_THICKNESS,
    border_radius: f32 = UI.BORDER_RADIUS,
    padding: Vec2 = .{ 0, 0 },
    margin: Vec2 = .{ 0, 0 },
    abs_offset: Vec2 = .{ 0, 0 },

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

    events: EventSet = .initEmpty(),
    scroll_mouse_event: EventSet = .initEmpty(),

    input: struct {
        utf8_storage: std.ArrayList(u21) = .empty,
        ascii_storage: std.ArrayList(u8) = .empty,
        cursor: u32 = 0,
        dirty: bool = false,
        dirty_t: f32 = 0,
        repeat_t: f32 = 0,


        const Input = @This();
        pub fn set_dirty(input: *Input) void {
            input.dirty = true;
            input.dirty_t = 0;
        }

        pub fn unset_dirty(input: *Input) void {
            input.dirty = false;
            input.dirty_t = 0;
        }

        const DIRTY_DELAY = 0.0;
        pub fn is_dirty(input: *Input) bool {
            return input.dirty and input.dirty_t >= DIRTY_DELAY;
        }
    } = .{},

    // UI logic state
    var selected_post_id: u32 = INVALID_INDEX;
    var selected_channel_id: u32 = INVALID_INDEX;
    var post_search_str: []const u21 = &.{};
    var add_url_status: []const u8 = " ";
    var display_add_popup = false;

    const INVALID_INDEX = std.math.maxInt(u32);

    pub const FilterOptions = struct {
        channel: u32 = INVALID_INDEX,
        name: []const u21 = &.{},
    };

    fn filter_post(filter: FilterOptions) void {
        selected_post_id = INVALID_INDEX;
        displayed_posts.clearRetainingCapacity();
        for (posts, post_title_codepoints, 0..) |post, title, i| {
            // TODO: optimize this
            if (filter.channel != INVALID_INDEX and filter.channel != post.channel)
                continue;
            if (filter.name.len > 0 and std.mem.indexOf(u21, title, filter.name) == null)
                continue;
            displayed_posts.append(gpa, @intCast(i)) catch @panic("OOM");
        }
    }

    pub fn filter_post_and_update() void {
        selected_post_id = INVALID_INDEX;
        filter_post(.{ .channel = selected_channel_id, .name = post_search_str });
    }

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

    const GAMMA = 1.2;
    const COLOR1 = RGBA.from_u32(0x37353eff).gamma(GAMMA);
    const COLOR2 = RGBA.from_u32(0x44444eff).gamma(GAMMA);
    const COLOR3 = RGBA.from_u32(0x715a5aff).gamma(GAMMA);
    const COLOR4 = RGBA.from_u32(0xffdab3ff).gamma(GAMMA);

    const TEXT_COLOR = RGBA.from_u32(0xd3dad9ff).gamma(GAMMA);

    const BORDER_RADIUS = 5;
    const BORDER_THICKNESS = 3;



    // UI Builder
    pub fn render() void {
        ctx.clear(.from_u32(0x303030ff));
        {
            _ = push_layout(.Y, "#outer", .{ .w_strategy = .span_screen, .h_strategy = .span_screen });

            const input_enabled = 
                switch (db_fetch_complete.load(.acquire)) {
                    .completed => blk: {
                        // TODO: use arena
                        // TODO: handle error
                        update_data();
                        db_fetch_complete.store(.idling, .release);
                        break :blk true;
                    },
                    .idling => true,
                    .fetching => false,
                };

            if (display_add_popup) {
                const POPUP_SIZE = Vec2 { (ctx.screen_w() * 0.5) / ctx.pixel_scale, 500 };
                const popup = push_layout(.Y, "#popup", .{ .w_strategy = .{ .fixed_in_pixels = POPUP_SIZE[0] }, .h_strategy = .fit_children, .border_color = COLOR3,
                    .flags = .initMany(&.{.absolute, .focusable }), .abs_offset = .{ (ctx.screen_w()-ctx.pixels(POPUP_SIZE[0]))/2, (ctx.screen_h()-ctx.pixels(POPUP_SIZE[1]))/-2 }});
                if (popup.events.contains(.Unfocused)) display_add_popup = false;
                // if (popup.mouse_event.contains(.Unfocused)) display_add_popup = false;
                const url = input_box_ascii("#add url text box", .{ .padding = .{ 10, 10 }, .margin = .{ 5, 5 },
                    .w_strategy = .{ .parent_perct = 1 }, .h_strategy = .fit_text,
                    .font_scale = 0.5, .flags = .initMany(&.{.focus_on_create}),
                    .bg_color = COLOR2, .border_color = TEXT_COLOR });
                get_last().flags.setPresent(.disabled, !input_enabled);

                text(frame_fmt("{s}#status text", .{ add_url_status }), .{ .font_scale = 0.3, .padding = .{ 10, 10 }, .margin = .{ 5, 5 }, 
                    .border_color = .transparent, .w_strategy = .{ .parent_perct = 1 } });
                if (text_btn("Confirm#add url confirm", .{ .padding = .{ 10, 10 }, .margin = .{ 5, 10 }, .font_scale = 0.5 })) {
                    db_mutex.lock();
                    defer db_mutex.unlock();
                    db_fetch_complete.store(.fetching, .release);
                    db_rss_url = url;
                    db_cond.signal();
                }
                get_last().flags.setPresent(.disabled, !input_enabled);
                
                pop_layout();
            }
            {
            _ = push_layout(.X, "#header", .{ .w_strategy = .rest_of_parent, .h_strategy = .fit_children, .bg_color = COLOR3, .border_color = RGBA.from_u32(0x715a5aff).gamma(1)});
            if (text_btn("Add#header", .{ .font_scale = 0.4, .padding = .{ 10, 10 }, .bg_color = .transparent, .border_color = RGBA.from_u32(0x715a5aff).gamma(1), .border_radius = 0 }))
                display_add_popup = true;
            pop_layout();
            }
            {
                _ = push_layout(.X, "#main", .{ .w_strategy = .{ .parent_perct = 1 }, .h_strategy = .rest_of_parent });
                const channel_layout = push_scroll_layout("channel_content",
                    .{ .padding = .{ 10, 10 }, .margin = .{ 10, 10 }, .w_strategy = .{ .parent_perct = 0.2 }, .h_strategy = .rest_of_parent });
                _ = channel_layout;
                for (channels) |channel| {
                    const selected = channel.rowid == selected_channel_id;
                    if (text_btn(frame_fmt("{s}#channel", .{ channel.title }),
                        .{ .padding = .{ 10, 10 }, .margin = .{ 4, 4 },
                            .font_scale = 0.5, .w_strategy = .{ .parent_perct = 1.0 },
                            .border_color = if (selected) .white else .transparent, .bg_color = if (selected) COLOR2 else .transparent,
                        })) {
                        if (selected) selected_channel_id = INVALID_INDEX
                        else selected_channel_id = channel.rowid;

                        filter_post_and_update();
                    }
                }
                pop_layout();
            }

            
            {
                _ = push_layout(.Y, "#post", .{ .w_strategy = .{ .parent_perct = 0.8 }, .h_strategy = .{ .parent_perct = 1 } });
                post_search_str = input_box_utf8("#post_search_box", .{ .w_strategy = .{ .parent_perct = 1}, .h_strategy = .fit_text,
                        .padding = .{ 10, 10 }, .margin = .{ 0, 5 },
                        .font_scale = 0.5,
                        .bg_color = COLOR2, .border_color = TEXT_COLOR
                });
                const search_box = get_last();
                if (search_box.input.is_dirty()) {
                    search_box.input.unset_dirty();
                    filter_post_and_update(); // this is blocking, but performance seams fine for now.
                }
                _ = push_scroll_layout("#post_content", .{ .w_strategy = .{ .parent_perct = 1 }, .h_strategy = .rest_of_parent, .flags = .initOne(.focus_on_create) });
                for (displayed_posts.items) |post_idx| {
                    const post = posts[post_idx];
                    const selected = post.rowid == selected_post_id;
                    if (text_btn(frame_fmt("{s}#post_title", .{ post.title }), 
                        .{ 
                            .padding = .{ 10, 20 }, .margin = .{ 10, 0 },
                            .border_color = if (selected) .white else .transparent, .bg_color = if (selected) COLOR2 else .transparent,
                            .font_scale = 0.5, .w_strategy = .{ .parent_perct = 1 },
                            .flags = .initMany(&.{.scissor, .highlight_text}),
                        })) {
                        if (selected) selected_post_id = INVALID_INDEX
                        else selected_post_id = post.rowid;
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
        focus_border_color: RGBA = COLOR4,
        border_width: f32 = UI.BORDER_THICKNESS,
        border_radius: f32 = UI.BORDER_RADIUS,
        padding: Vec2 = .{ 0, 0 },
        margin: Vec2 = .{ 0, 0 },
        abs_offset: Vec2 = .{ 0, 0 },
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
        input_box,
        disabled,
        animated,
        focusable,
        focus_on_create,
        absolute,
        highlight_text,
    };

    pub const MouseEvent = enum {
        Hover,
        Down,
        Clicked,
        Focused,
        Unfocused,
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
        const ui = new(content, opts);     
        ui.text_content = .{ .ascii = preprocess_text(content) };
        ui.add_to_layout();
    }

    pub fn text_btn(content: []const u8, opts: UIOptions) bool {
        const ui = new(content, opts);     

        ui.text_content = .{ .ascii = preprocess_text(content) };
        ui.flags.setPresent(.button, true);
        ui.add_to_layout();
        return ui.events.contains(.Clicked);
    }

    // TODO: deal with utf-8
    pub fn input_box_utf8(str_hash: []const u8, opts: UIOptions) []const u21 {
        const ui = new(str_hash, opts);
        ui.flags.setPresent(.focusable, true);
        ui.flags.setPresent(.input_box, true);
        ui.add_to_layout();
        const dt = ctx.get_delta_time();
        if (ui.events.contains(.Focused)) {
            if (prev_hash.get(str_hash)) |prev_ui| {
                ctx.ime_set_composition_windows(prev_ui.resolved_origin[0], -(prev_ui.resolved_origin[1]) + prev_ui.resolved_size[1]);
            }
            const new_chars_ct = UI.input_chars.items.len;
            ui.input.utf8_storage.insertSlice(gpa, ui.input.cursor, UI.input_chars.items) catch unreachable;
            ui.input.cursor += @intCast(new_chars_ct);

            if (new_chars_ct > 0)
                ui.input.set_dirty();

            const ch_to_removed = @min(ui.input.cursor, UI.backspace);
            for (0..ch_to_removed) |_| {
                _ = ui.input.utf8_storage.orderedRemove(ui.input.cursor-1);
                ui.input.cursor -= 1;
                ui.input.set_dirty();
            }

            if (ctx.is_paste) {
                const buf = ctx.clipboard();
                ui.input.cursor += gl.append_utf8_slice(&ui.input.utf8_storage, gpa, buf) catch @panic("TODO: handle invalid utf8 sequence");
                ui.input.set_dirty();
            }

            // TODO: handle this like backspace
            // Cursor movement
            if (ctx.is_key_pressed(.Left) and ui.input.cursor > 0) {
                ui.input.cursor -= 1;
            }
            if (ctx.is_key_pressed(.Right) and ui.input.cursor < ui.input.utf8_storage.items.len) {
                ui.input.cursor += 1;
            }
        }

        if (ui.input.dirty)
            ui.input.dirty_t += dt;
        
        if (ui.events.contains(.Hover))
            mouse_icon = .mouse_ibeam;

        
        ui.text_content = .{ .utf8 = ui.input.utf8_storage.items };
        return ui.text_content.utf8;
    }

    pub fn input_box_ascii(str_hash: []const u8, opts: UIOptions) []const u8 {
        const ui = new(str_hash, opts);
        ui.flags.setPresent(.focusable, true);
        ui.flags.setPresent(.input_box, true);
        ui.add_to_layout();
        const dt = ctx.get_delta_time();
        if (ui.events.contains(.Focused)) {
            ctx.ime_disable_composition();
            var new_chars_ct: u32 = 0;
            for (UI.input_chars.items) |codepoint| {
                if (codepoint > std.math.maxInt(u8)) continue;
                const ascii: u8 = @intCast(codepoint);
                if (!std.ascii.isAscii(ascii)) continue;
                ui.input.ascii_storage.insert(gpa, ui.input.cursor, ascii) catch @panic("OOM");
                ui.input.cursor += 1;
                new_chars_ct += 1;
            }

            if (new_chars_ct > 0)
                ui.input.set_dirty();

            const ch_to_removed = @min(ui.input.cursor, backspace);
            for (0..ch_to_removed) |_| {
                _ = ui.input.ascii_storage.orderedRemove(ui.input.cursor-1);
                ui.input.cursor -= 1;
                ui.input.set_dirty();
            }

            if (ctx.is_paste) {
                // TODO: validate ascii
                const buf = ctx.clipboard();
                ui.input.ascii_storage.appendSlice(gpa, buf) catch @panic("OOM");
                ui.input.cursor += @intCast(buf.len);
                ui.input.set_dirty();
            }

            // TODO: handle this like backspace
            // Cursor movement
            if (ctx.is_key_pressed(.Left) and ui.input.cursor > 0) {
                ui.input.cursor -= 1;
            }
            if (ctx.is_key_pressed(.Right) and ui.input.cursor < ui.input.ascii_storage.items.len) {
                ui.input.cursor += 1;
            }
        }

        if (ui.input.dirty)
            ui.input.dirty_t += dt;

        if (ui.events.contains(.Hover))
            mouse_icon = .mouse_ibeam;

        ui.text_content = .{ .ascii = ui.input.ascii_storage.items };
        return ui.text_content.ascii;
    }

    fn new(str_hash: []const u8, opts: UIOptions) *UI {
        assert(str_hash.len != 0);
        const ui = curr_arena.create(UI) catch unreachable;
        ui.* = UI { .str_hash = str_hash };
        set_opts(ui, opts);

        curr_hash.putNoClobber(str_hash, ui) catch unreachable;
        if (prev_hash.get(str_hash)) |prev_ui| {
            ui.resolved_size = prev_ui.resolved_size; // TODO: clean this up so we have one place doing all the copying
            ui.anim_completed = prev_ui.anim_completed;
            ui.events = prev_ui.events;

            ui.scroll_offset = prev_ui.scroll_offset;
            ui.children_bounding_size = prev_ui.children_bounding_size;
            ui.resolved_origin = prev_ui.resolved_origin;
            ui.scroll_mouse_event = prev_ui.scroll_mouse_event;
            
            ui.input = prev_ui.input;
        } else if (ui.flags.contains(.focus_on_create)) {
            force_focus_on = str_hash;
        }
        return ui;
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
    pub var root_layout: *UI = undefined; // we assume the builder code is going to push at least one layout

    pub fn push_layout(axis: Axis, str_hash: []const u8, opts: UIOptions) *UI {
        const layout = new(str_hash, opts);
        layout.flags.setPresent(.layout, true);
        layout.layout_axis = axis;

        if (layouts_stack.items.len == 0) {
            root_layout = layout;
        } else {
            layout.add_to_layout();
        }
        layouts_stack.append(gpa, layout) catch @panic("OOM");

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
            const scroll_h = layout.children_bounding_size[1];
            const display_h = prev_layout.resolved_size[1];
            if (scroll_h > display_h) {
                // TODO: arrow key?
                // handlem mouse scroll
                if (layout.events.contains(.Focused))
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

    fn get_last() *UI {
        const layout = get_curr_layout();
        return layout.children.getLastOrNull() orelse layout;
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

        mouse_icon = .mouse_normal;
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
        var happened = EventSet.initEmpty();
        _ = resolve_input_event_impl(prev_root_layout orelse return, &happened);
        force_focus_on = "";
    }

    // FIXME: hacky function
    pub fn handle_mouse(box: Box) EventSet {
        var mouse_state = EventSet.initEmpty();
        const hover = mouse_within_rect(box);
        mouse_state.setPresent(.Hover, hover);
        mouse_state.setPresent(.Clicked, hover and ctx.is_mouse_released(.mouse_left));
        mouse_state.setPresent(.Down, hover and ctx.is_mouse_down(.mouse_left));
        mouse_state.setPresent(.Focused, mouse_state.contains(.Clicked));
        mouse_state.setPresent(.Unfocused, !mouse_state.contains(.Hover) and ctx.is_mouse_released(.mouse_left));
        return mouse_state;
    }

    fn resolve_input_event_impl(node: *UI, happened: *EventSet) void {
        const is_prev_focused = node.events.contains(.Focused);
        node.events = .initEmpty();
        if (node.flags.contains(.disabled)) return;
        node.events.setPresent(.Focused, is_prev_focused and !ctx.is_mouse_released(.mouse_left));
        // FIXME: use scissor?
        // const border = node.get_border_box().intersect(parent_border) orelse return;
        const border = node.get_border_box();
        node.events.setUnion(handle_mouse(border));
        if (!node.flags.contains(.focusable)) node.events.setPresent(.Focused, false);
        if (force_focus_on.len > 0) {
            node.events.setPresent(.Focused, std.mem.eql(u8, node.str_hash, force_focus_on));
        }

        if (node.flags.contains(.y_scroll)) {
            node.scroll_mouse_event = .initEmpty();
            node.scroll_mouse_event.setUnion(handle_mouse(node.get_scroll_bar_box()));
        }

        for (node.children.items) |child| {
            resolve_input_event_impl(child, happened);
        }
    
        happened.setPresent(.Unfocused, false);
        node.events.setIntersection(happened.complement());
        happened.setUnion(node.events);
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
                    node.target_size[0] = 2*ctx.pixels(node.padding[0] + node.margin[0]) + node.text_content.width(node.font_scale, .{ 0, node.text_content.len() });
                },
                .fixed_in_pixels => |p| node.target_size[0] = ctx.pixels(2*(node.padding[0] + node.margin[0]) + p),
                .fixed_in_normalized => |size| node.target_size[0] = ctx.pixels(2*(node.padding[0] + node.margin[0])) + size,
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
                .fixed_in_normalized => |size| node.target_size[1] = ctx.pixels(2*(node.padding[1] + node.margin[1])) + size,
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
        node.resolved_size = v2scal(node.resolved_size, ctx.pixel_scale/prev_pixel_scale);
        if (maybe_parent) |parent| {
            assert(parent.flags.contains(.layout));
            if (!node.flags.contains(.absolute)) {
                node.resolved_origin = v2add(parent.resolved_origin, parent.layout_offset);
            } else {
                node.resolved_origin = v2add(parent.resolved_origin, node.abs_offset);
            }
        } else {
            // topleft corner of the screen
            node.resolved_origin = .{ ctx.x_left(), ctx.y_top() };
        }

        resolve_size_pre_order(maybe_parent, node); 
        {
            var largest_child = Vec2 { 0, 0 };  
            node.layout_offset[0] += ctx.pixels(node.padding[0] + node.margin[0]);
            node.layout_offset[1] -= ctx.pixels(node.padding[1] + node.margin[1]);
            for (node.children.items) |child| {
                // before recurring into this function, make sure the origin of `node` is resolved
                if (child.flags.contains(.absolute)) continue;
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
        }
        resolve_size_post_order(maybe_parent, node);
        for (node.children.items) |child| {
            // before recurring into this function, make sure the origin of `node` is resolved
            if (!child.flags.contains(.absolute)) continue;
            resolve_layout_impl(node, child);
        }
        for (node.children.items) |child| {
            offset_origin_recursive(child, .{ 0, node.scroll_offset * node.children_bounding_size[1]});
        }

    }
};

fn parse_rss(reader: *std.Io.Reader) parser.ParserError!DB.Channel {
    var streaming_reader: xml.Reader.Static = .init(gpa, reader, .{});
    defer streaming_reader.deinit();
    const xml_reader = &streaming_reader.interface;

    
    try parser.expect_next(xml_reader, .xml_declaration); 
    // try stdout.print("xml_declaration: version={s} encoding={?s} standalone={?}\n", .{
    //     xml.reader.xmlDeclarationVersion(),
    //     xml.reader.xmlDeclarationEncoding(),
    //     xml.reader.xmlDeclarationStandalone(),
    // });

    try parser.expect_element_start_name(xml_reader, "rss");
    // try parser.expect_element_start_name(xml_reader, "channel");
    const channel = try parser.parse_struct(DB.Channel, xml_reader, "channel", db_arena_state.allocator()); 
    parser.expect_element_end_name(xml_reader, "rss") catch |e| {
        std.log.warn("{}: there are probably multiple channels, not supported right now", .{ e });     
    };
    return channel;
}

// Only one channel is supported
fn parse_rss_buf(buf: []const u8) parser.ParserError!DB.Channel {
    var streaming_reader: xml.Reader.Static = .init(gpa, buf, .{});
    defer streaming_reader.deinit();
    const xml_reader = &streaming_reader.interface;

    
    try parser.expect_next(xml_reader, .xml_declaration); 
    // try stdout.print("xml_declaration: version={s} encoding={?s} standalone={?}\n", .{
    //     xml.reader.xmlDeclarationVersion(),
    //     xml.reader.xmlDeclarationEncoding(),
    //     xml.reader.xmlDeclarationStandalone(),
    // });

    try parser.expect_element_start_name(xml_reader, "rss");
    // try parser.expect_element_start_name(xml_reader, "channel");
    const channel = try parser.parse_struct(DB.Channel, xml_reader, "channel", db_arena_state.allocator()); 
    parser.expect_element_end_name(xml_reader, "rss") catch |e| {
        std.log.warn("{}: there are probably multiple channels, not supported right now", .{ e });     
    };
    return channel;
}

fn fetch_rss_and_update(url: []const u8)
    (std.http.Client.FetchError || parser.ParserError || DB.Error)!void 
{
    var client = std.http.Client { .allocator = gpa };
    defer client.deinit();

    var fetch_sink = std.Io.Writer.Allocating.init(gpa);
    defer fetch_sink.deinit();

    const fetch_res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &fetch_sink.writer,
    });
    std.log.info("fetching {s}: {}", .{ url, fetch_res.status });

    // var stdout_buf: [4096]u8 = undefined;
    // var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    // const stdout = &stdout_writer.interface;


    const channel = try parse_rss_buf(fetch_sink.written());
    std.debug.print("Channel: {s}\n{s}\n{s}\n", .{ channel.title, channel.link, channel.description });
    std.debug.print("Channel extra: {s}\n", .{ channel.language });
    for (channel.item) |item| {
        std.debug.print("item {s}\n", .{item.title});
    }

    try db.add_posts(channel);

}

var db: DB = undefined; // @init_on_main
var channels: []DB.ChannelWithId = undefined; // @init_on_main
var posts: []DB.ItemWithChannel = undefined; // @init_on_main
var post_title_codepoints: [][]u21 = undefined; // @init_on_main
var displayed_posts: std.ArrayList(u32) = .empty;

var should_quit = false;

var db_mutex = std.Thread.Mutex {};
var db_cond = std.Thread.Condition {};
var db_rss_url: []const u8 = &.{};
var db_arena_state: std.heap.ArenaAllocator = undefined; // @init_on_main;
const fetch_status = enum(u8) {
    idling,
    fetching,
    completed,
};
var db_fetch_complete: std.atomic.Value(fetch_status) = .init(.idling);

fn db_worker() void {
    db_mutex.lock();
    defer db_mutex.unlock();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    while (!should_quit) {
        db_cond.wait(&db_mutex);
        if (should_quit) break;
        _ = arena.reset(.retain_capacity);
        UI.add_url_status =  "Fetching...";
        if (fetch_rss_and_update(db_rss_url)) {
            UI.add_url_status = "Fetch successful!";
        } else |e| {
            switch (e) {
                error.InvalidFormat => 
                    UI.add_url_status = "Invalid url",
                else => 
                    UI.add_url_status = std.fmt.allocPrint(gpa, "Unexpected Error: {}", .{e}) catch @panic("OOM"),
            }
        }
        db_fetch_complete.store(.completed, .release);
    }
}

fn update_data() void {
    // TODO: memory leak
    // TODO: handle error
    channels = db.get_channels_all(gpa) catch unreachable;
    posts = db.get_posts_all(gpa) catch unreachable;
    post_title_codepoints = gpa.alloc([]u21, posts.len) catch @panic("OOM");
    for (posts, post_title_codepoints) |post, *codepoints| {
        const codepoints_count = std.unicode.utf8CountCodepoints(post.title) catch 0;
        codepoints.* = gpa.alloc(u21, codepoints_count) catch @panic("OOM");
        var it = std.unicode.Utf8View.initUnchecked(post.title).iterator();
        for (codepoints.*) |*codepoint| {
            codepoint.* = it.nextCodepoint().?;
        }
    }
}

const Key = gl.Context.Key;
const KeyMod = gl.Context.KeyMod;

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

    db_arena_state = .init(gpa);

    
    std.log.debug("init database.", .{});
    db = try DB.init("feed.db");
    defer db.deinit();

    update_data();
    UI.filter_post_and_update();

    defer { 
        UI.key_hash[0].deinit(); UI.key_hash[1].deinit(); 
        UI.ui_arena_state[0].deinit(); UI.ui_arena_state[1].deinit(); 
        UI.tmp_arena_state.deinit();
    }

    try gl.Context.init(&ctx, Renderer.render, "RSS Reader", 1920, 1024, gpa);

    UI.prev_pixel_scale = ctx.pixel_scale;

    var db_worker_t = try std.Thread.spawn(.{}, db_worker, .{});
    while (!ctx.window_should_close()) {
        UI.input_chars.clearRetainingCapacity();
        UI.backspace = 0;
        UI.is_paste = false;
        while (ctx.poll_event()) |event| {
            switch (event) {
                .composition => |composition| {

                    UI.input_chars.appendSlice(gpa, composition.codepoints) catch @panic("OOM");
                },
                .key_char => |codepoint| {
                    if (codepoint == @intFromEnum(Key.BackSpace))
                        UI.backspace += 1
                    else if (codepoint <= std.math.maxInt(u8)) {
                        const ascii: u8 = @intCast(codepoint);
                        if (ascii >= gl.Context.code_first_char and ascii <= gl.Context.code_last_char)
                            UI.input_chars.append(gpa, codepoint) catch @panic("OOM");
                    } else
                        UI.input_chars.append(gpa, codepoint) catch @panic("OOM");
                    // if (std.enums.fromInt(Key, pressed.sym)) |sym| {
                    //     if (sym == Key.backSpace)
                    //         UI.backspace += 1
                    //     else if (sym != Key.keyNULL and sym != Key.escape and std.ascii.isAscii(pressed.sym))
                    // } else {
                    //     // if (pressed.sym == Key.v and pressed.mod.contains(.Control)) UI.is_paste = true
                    // }
                }
            }
        }
        ctx.render();
    }
    ctx.close_window();

    should_quit = true;

    db_cond.signal();
    db_worker_t.join();
}

pub const SMOOTH_SPD = 50;
pub fn exp_smooth(x: f32, target: f32, dt: f32) f32 {
    return x + (target - x) * (1 - @exp(-dt * SMOOTH_SPD));
}
