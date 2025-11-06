const std = @import("std");
const log = std.log;

const xml = @import("xml");

const Sqlite = @import("sqlite.zig");
const parser = @import("xml_parser.zig");

const gl = @import("gl");
const Vec2 = gl.Vec2;
const c = gl.c;

const RGBA = gl.RGBA;


const assert = std.debug.assert;
const fatal = std.process.fatal;
const Allocator = std.mem.Allocator;

pub const Item = struct {
    title: [:0]const u8,
    pubDate: [:0]const u8,
    link: [:0]const u8,
    guid: [:0]const u8,
    description: [:0]const u8,
};

pub const Channel = struct {
    title: [:0]const u8,
    link: [:0]const u8,
    description: [:0]const u8,
    language: [:0]const u8 = "",
    item: []Item,
};

const INVALID_INDEX = std.math.maxInt(u32);

// Only one channel is supported
fn parse_rss(reader: *std.Io.Reader, gpa: Allocator, arena: Allocator) parser.ParserError!Channel {
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
    const channel = try parser.parse_struct(Channel, xml_reader, "channel", arena); 
    parser.expect_element_end_name(xml_reader, "rss") catch |e| {
        std.log.warn("{}: there are probably multiple channels, not supported right now", .{ e });     
    };
    return channel;
}

// Only one channel is supported
fn parse_rss_buf(buf: []const u8, gpa: Allocator, arena: Allocator) parser.ParserError!Channel {
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
    const channel = try parser.parse_struct(Channel, xml_reader, "channel", arena); 
    parser.expect_element_end_name(xml_reader, "rss") catch |e| {
        std.log.warn("{}: there are probably multiple channels, not supported right now", .{ e });     
    };
    return channel;
}

fn fetch_rss_and_update(url: []const u8, db: *Sqlite, gpa: Allocator, arena: Allocator)
    (std.http.Client.FetchError || parser.ParserError || Sqlite.Error)!void 
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


    const channel = try parse_rss_buf(fetch_sink.written(), gpa, arena);
    std.debug.print("Channel: {s}\n{s}\n{s}\n", .{ channel.title, channel.link, channel.description });
    std.debug.print("Channel extra: {s}\n", .{ channel.language });
    for (channel.item) |item| {
        std.debug.print("item {s}\n", .{item.title});
    }

    try db.add_posts(channel);

}

var should_quit = false;

var db_mutex = std.Thread.Mutex {};
var db_cond = std.Thread.Condition {};
var db_rss_url: []const u8 = "";

var err_text: []const u8 = "";
var err_text_t: f32 = 0;
var err_text_anim: UI.Anim = .{};
var err_text_arena: std.heap.ArenaAllocator = undefined;

var db_fetch_complete: std.atomic.Value(bool) = .init(false);

fn db_worker(db: *Sqlite, gpa: Allocator) void {
    db_mutex.lock();
    defer db_mutex.unlock();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    while (!should_quit) {
        db_cond.wait(&db_mutex);
        if (should_quit) break;
        _ = arena.reset(.retain_capacity);
        set_annoucement("Fetching...", .{}, std.math.floatMax(f32));
        if (fetch_rss_and_update(db_rss_url, db, gpa, arena.allocator())) {
            set_annoucement("Fetch successful!", .{}, 5);
        } else |e| {
            switch (e) {
                error.InvalidFormat => 
                    set_annoucement("Invalid url", .{}, 5),
                else => 
                    set_annoucement("Unexpected Error: {}", .{e}, 5),
            }
        }
        db_fetch_complete.store(true, .release);
        
    }
}

fn set_annoucement(comptime fmt: []const u8, args: anytype, t: f32) void {
    _ = err_text_arena.reset(.retain_capacity);
    err_text = std.fmt.allocPrint(err_text_arena.allocator(), fmt, args) catch unreachable;
    err_text_t = t;
    err_text_anim.x = 0;
    err_text_anim.target = 1;
}

const UIContext = gl.Context(UI);
const UI = struct {
    const scroll_spd = 0.5;
    const repeat_rate = 15.0; // x times every second
    const input_filter_delay = 0.2;
                              
    gpa: Allocator,

    main_scroll: Scroll = .{ .scroll = 0, .clicked = false },
    input: Input = .{},

    db: *Sqlite,

    posts: []Sqlite.ItemWithChannel,
    displayed_posts: std.ArrayList(u32) = .empty,
    channels: []Sqlite.ChannelWithId,

    // filter: FilterOptions = .{},
    selected_channel: u32 = INVALID_INDEX,
    selected_post: u32 = INVALID_INDEX,

    expand_anim: Anim = .{},

    repeat_t: f32 = 0,
    
    // const titles: []const []const u8 = &.{ "Title A", "Title B" };
    pub const Scroll = struct {
        scroll: f32,
        clicked: bool,
    };

    pub const Input = struct {
        content: std.ArrayList(u8) = .empty,
        focused: bool = false,
        cursor: u32 = 0,

        dirty: bool = false,
        dirty_t: f32 = 0,

        pub fn set_dirty(input: *Input) void {
            input.dirty = true;
            input.dirty_t = 0;
        }

        pub fn unset_dirty(input: *Input) void {
            input.dirty = false;
            input.dirty_t = 0;
        }

        pub fn is_dirty(input: *Input, t: f32) bool {
            return input.dirty and input.dirty_t >= t;
        }
    };

    pub const Anim = struct {
        pub const SMOOTH_SPD = 50;
        x: f32 = 0,
        target: f32 = 0,

        pub fn update(self: *Anim, dt: f32) void {
            self.x += (self.target - self.x) * (1 - @exp(-dt * Anim.SMOOTH_SPD));
        }
    };

    pub const FilterOptions = struct {
        channel: u32 = INVALID_INDEX,
        name: []const u8 = "",
    };

    // Defines a box by its bottem left corner and size.
    //
    //      |------|
    //      |      | h
    //      |------|
    //     /   w   
    //  (x,y)
    //
    // Some helpers are provided to create from other position.
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

    fn reset_display_post_to_default(ui: *UI) void {
        ui.displayed_posts.clearRetainingCapacity();
        for (0..ui.posts.len) |i| {
            ui.displayed_posts.append(ui.gpa, @intCast(i)) catch @panic("OOM");
        }
    }

    fn filter_post(ui: *UI, filter: FilterOptions) void {
        ui.displayed_posts.clearRetainingCapacity();
        for (ui.posts, 0..) |post, i| {
            if (filter.channel != INVALID_INDEX and filter.channel != post.channel)
                continue;
            if (filter.name.len > 0 and std.mem.indexOf(u8, post.title, filter.name) == null)
                continue;
            ui.displayed_posts.append(ui.gpa, @intCast(i)) catch @panic("OOM");
        }
    }

    fn filter_and_update(ui: *UI) void {
        ui.selected_post = INVALID_INDEX;
        ui.filter_post(.{ .channel = ui.selected_channel, .name = ui.input.content.items });

    }

    fn render(ctx: *UIContext) void {
        const ui = ctx.user_data;
        const dt = ctx.get_delta_time();

        ctx.clear(.from_u32(0x303030ff));
        const menu_h = ctx.cal_font_h(0.5) * 2;

        const plus_size = ctx.get_char_size(1, '+');
        const add_btn_side = menu_h;
        const top_menu_y_center = ctx.y_top()-add_btn_side/2.0-0.015;
        const add_box = Box.from_centerleft(.{ ctx.x_left()+0.01, top_menu_y_center }, .{ add_btn_side, add_btn_side });

        // 
        // TOP MENU
        //
        if (button_ex(ctx, add_box, 1, "+",
                .{ (add_box.size[0]-plus_size[0])/2-ctx.pixels(1), (add_box.size[1]-plus_size[1])/2 })) {
            db_mutex.lock();
            defer db_mutex.unlock();
            const url = ui.input.content.items;

            db_fetch_complete.store(false, .release);
            db_rss_url = url;
            db_cond.signal();
            // fetch_rss_and_update(url, ui.db, ui.gpa, arena.allocator()) catch |e| {
            //     std.log.err("failed to fetch and update rss from {s}: {}", .{ url, e });
            // };
        }

        const url_box = Box.from_centerleft(.{ add_box.x_right() + 0.01, top_menu_y_center }, .{ 1, add_btn_side*0.75 });
        input_box(ctx,
            url_box,
            &ui.input, "Enter url of rss here...", ui.gpa);
        // std.log.debug("dirty: {} {} ", .{ui.input.dirty, ui.input.dirty_t});
        if (ui.input.is_dirty(input_filter_delay)) {
            ui.input.unset_dirty();
            ui.filter_and_update();
        }

        if (db_fetch_complete.load(.acquire)) {
            ui.posts = ui.db.get_posts_all(ui.gpa) catch unreachable;
            ui.channels = ui.db.get_channels_all(ui.gpa) catch unreachable;
        }

        if (err_text_t > 0) err_text_t -= dt
        else err_text_anim.target = 0;
        err_text_anim.update(dt/10);
        text_box(ctx, .from_centerleft(.{ url_box.x_right() + 0.01, top_menu_y_center }, url_box.size), 0.5, err_text, 
            .{ .r = 0xff, .g = 0xff, .b = 0xff, .a = @intFromFloat(255.0 * err_text_anim.x ) }, .midleft);

        //
        // LEFT PANEL
        //
        const left_box = Box { .botleft = .{ ctx.x_left(), ctx.y_bot() }, .size = .{ 0.3, add_box.botleft[1]-(ctx.y_bot()) - 0.015 } };
        ctx.begin_scissor_gl_coord(left_box.botleft, left_box.size);
        for (ui.channels, 1..) |channel, i| {
            const if32: f32 = @floatFromInt(i);
            const box = Box.from_botleft(
                .{ ctx.x_left(), left_box.y_top()-if32*menu_h }, 
                .{ 0.3, menu_h });
            const iu32: u32 = @intCast(i);

            if (iu32 == ui.selected_channel) ctx.draw_rect(box.botleft, box.size, .{ .r = 0xff, .g = 0xff, .b = 0, .a = 0x3f });

            if (button(
                    ctx,
                    box,
                    0.5,
                    channel.title,
                    .midleft)) {

                if (ui.selected_channel == iu32) {
                    ui.selected_channel = INVALID_INDEX;
                    ui.reset_display_post_to_default();
                } else {
                    ui.selected_channel = iu32;
                    ui.filter_and_update();
                }
                // std.log.debug("Cliekd", .{}); 
                // ui.selected_title = channel_title;
            }
        }
        ctx.end_scissor();

        

        // ctx.draw_text(.{ ctx.x_left()+add_btn_side+0.05, ctx.y_top()-(add_btn_side+ctx.cal_font_h(0.5))/2-0.015}, 0.5, ui.input.items, .white);
        // ctx.draw_rect(.{ add_btn_pos[0]+(add_btn_size[0]-plus_size[0])/2, add_btn_pos[1]+(add_btn_size[1]-plus_size[1])/2 }, plus_size,.white);


        // ctx.draw_rect_lines(.{ ctx.x_left(), ctx.y_bot() }, .{ 0.3, ctx.screen_h() }, 5, .from_u32(0xffffff30));

        const main_box = Box { .botleft = .{ ctx.x_left()+0.3, ctx.y_bot() }, .size = .{ ctx.screen_w()-left_box.size[0], left_box.size[1] } };
        ctx.begin_scissor_gl_coord(main_box.botleft, main_box.size);
        // const titles_h = @as(f32, @floatFromInt(ui.posts.len)) * btn_h;
        const total_titles_h = (@as(f32, @floatFromInt(ui.displayed_posts.items.len)) + ui.expand_anim.x * 3) * menu_h;

        var titles_h: f32 = 0;
        for (ui.displayed_posts.items, 0..) |post_idx, i| {
            const post = ui.posts[post_idx];
            // const if32: f32 = @floatFromInt(i+1);
            
            titles_h += menu_h;
            if (button(
                    ctx,
                    .from_botleft(
                        .{ main_box.botleft[0], main_box.top(0)-titles_h + ui.main_scroll.scroll*total_titles_h }, 
                        .{  ctx.screen_w()-0.3, menu_h }),
                    0.5,
                    post.title,
                    .midleft)) {

                if (ui.selected_post != @as(u32, @intCast(i))) {
                    ui.selected_post = @intCast(i);
                    ui.expand_anim.x = 0;
                    ui.expand_anim.target = 1;
                }
                else {
                    ui.expand_anim.target = 0;
                }
                // std.log.debug("Cliekd", .{}); 
            }
            if (ui.selected_post == i) {
                // draw a dropdown menu under the selected item
                // ui.expand_anim.x += (ui.expand_anim.target - ui.expand_anim.x) * (1 - @exp(-dt * Anim.SMOOTH_SPD));
                ui.expand_anim.update(dt);
                // std.log.info("anim: {}, target: {}({})", .{ui.expand_anim.x, ui.expand_anim.target, menu_h * 3});
                titles_h += ui.expand_anim.x*menu_h*3;
                if (button(
                    ctx,
                    .from_botleft(
                        .{ main_box.botleft[0], main_box.top(0)-titles_h + ui.main_scroll.scroll*total_titles_h }, 
                        .{  ctx.screen_w()-0.3, ui.expand_anim.x*menu_h*3 }),
                    0.5,
                    if (ui.expand_anim.x > 0.5) post.link else "",
                    .topleft)) {
                    ctx.set_clipboard(post.link);

                    set_annoucement("Url copied to cliboard.", .{}, 5);
                }

                if (std.math.approxEqAbs(f32, ui.expand_anim.x, 0, 0.001)) ui.selected_post = INVALID_INDEX;
                // gl.c.RGFW_writeClipboard(post.link.ptr, @intCast(post.link.len));
            } 

        }
        ctx.end_scissor();

        scroll_box(ctx, main_box, &ui.main_scroll, total_titles_h);
        ctx.draw_rect_lines(main_box.botleft, main_box.size, 1, .yellow);
        // std.log.info("Mouse gl pos: {any} {any}", .{ctx.mouse_pos_gl, ctx.mouse_pos_screen});
        // std.log.info("Mouse scroll: {any}", .{ctx.mouse_scroll});
    }

    const TextBoxExOptions = struct {
        box: Box,
        font_size: f32 = 0.5,
        text: []const u8,
        text_offset: Vec2,
        text_color: RGBA = .white,
        bg_color: RGBA = .transparent,
        border_color: ?RGBA = .from_u32(0xffffff30),
    };

    pub const TextAlignment = enum {
        topleft,
        midleft,
        botleft,
    };

    pub fn align_text(ctx: *UIContext, box: Box, font_size: f32, alignment: TextAlignment) Vec2 {
        switch (alignment) {
            .topleft => {
                return .{ ctx.pixels(5), (box.size[1]-ctx.cal_font_h(font_size)) };
            },
            .midleft => {
                return .{ ctx.pixels(5), (box.size[1]-ctx.cal_font_h(font_size))/2 };
            },
            .botleft => {
                return .{ ctx.pixels(5), 0 };
            },
        }
    }

    fn text_box_ex(ctx: *UIContext, opt: TextBoxExOptions) void {
        const box = opt.box;
        ctx.draw_rect(box.botleft, box.size, opt.bg_color);
        if (opt.border_color) |border_color| ctx.draw_rect_lines(box.botleft, box.size, 5, border_color);
        ctx.draw_text(.{ 
            box.botleft[0] + opt.text_offset[0],
            box.botleft[1] + opt.text_offset[1] }, opt.font_size, opt.text, opt.text_color);
    }

    fn text_box(ctx: *UIContext, 
        box: Box,
        font_size: f32,
        text: []const u8,
        text_color: RGBA,
        alignment: TextAlignment,
    ) void {
        return text_box_ex(ctx, .{
            .box = box,
            .font_size = font_size,
            .text = text,
            .text_offset = align_text(ctx, box, font_size, alignment),
            .text_color = text_color,
            .bg_color = .transparent,
        });
    }

    fn button_ex(ctx: *UIContext, box: Box, font_size: f32, text: []const u8, text_offset: Vec2) bool {
        const within = within_rect(ctx.mouse_pos_gl, box);
        const bg_color: RGBA = 
            if (within)
                if (gl.c.RGFW_isMouseDown(gl.c.RGFW_mouseLeft) == 1)
                    .from_u32(0x00000030)
                else
                    .from_u32(0xffffff30)
            else
                .transparent;

        text_box_ex(ctx, .{
            .box = box,
            .font_size = font_size,
            .text = text,
            .text_offset = text_offset,
            .text_color = .white,
            .bg_color = bg_color,
        });

        return within and gl.c.RGFW_isMouseReleased(gl.c.RGFW_mouseLeft) == 1;
    }

    fn button(ctx: *UIContext, box: Box, font_size: f32, text: []const u8, alignment: TextAlignment) bool {
        return button_ex(ctx, box, font_size, text, align_text(ctx, box, font_size, alignment));
    }

    fn input_box(ctx: *UIContext, box: Box, input: *Input, hint_text: []const u8, a: Allocator) void {
        const font_size = 0.5;
        ctx.draw_rect(box.botleft, box.size, .white); 
        const text_offset = Vec2 { ctx.pixels(5), (box.size[1]-ctx.cal_font_h(font_size))/2 };
        if (input.content.items.len > 0)
            ctx.draw_text(.{ box.botleft[0] + text_offset[0], box.botleft[1] + text_offset[1] }, font_size, input.content.items, .black)
        else
            ctx.draw_text(.{ box.botleft[0] + text_offset[0], box.botleft[1] + text_offset[1] }, font_size, hint_text, .from_u32(0x7f7f7fff));

        const within = mouse_within_rect(ctx, box);

        if (within)
            _ = gl.c.RGFW_window_setMouseStandard(ctx.window, gl.c.RGFW_mouseIbeam)
        else
            _ = gl.c.RGFW_window_setMouseStandard(ctx.window, gl.c.RGFW_mouseNormal);

        if (ctx.mouse_left)
            input.focused = within;

        if (input.focused) {
            const dt = ctx.get_delta_time();
            ctx.draw_rect_lines(box.botleft, box.size, 5, .yellow);

            const new_chars_ct = ctx.input_chars.items.len;
            input.content.appendSlice(a, ctx.input_chars.items) catch unreachable;
            input.cursor += @intCast(new_chars_ct);

            if (new_chars_ct > 0)
                input.set_dirty();

            if (gl.c.RGFW_isKeyDown(gl.c.RGFW_backSpace) == 1) {
                for (0..ctx.user_data.repeat(dt)) |_| {
                    if (input.content.items.len == 0) break;
                    input.content.shrinkRetainingCapacity(input.content.items.len-1);
                    input.cursor -= 1;

                    input.set_dirty();
                }
            }
            if (ctx.is_paste) {
                const buf = ctx.clipboard();
                input.content.appendSlice(a, buf) catch unreachable;
                input.cursor += @intCast(buf.len);

                input.set_dirty();
            }

            // Cursor movement
            if (gl.c.RGFW_isKeyPressed(gl.c.RGFW_left) == 1 and input.cursor > 0) {
                input.cursor -= 1;
            }
            if (gl.c.RGFW_isKeyPressed(gl.c.RGFW_right) == 1 and input.cursor < input.content.items.len) {
                input.cursor += 1;
            }

            const tw = ctx.text_width(font_size, input.content.items[0..input.cursor]);
            const end_of_text = box.botleft[0] + text_offset[0] + tw;
            const cursor_box = Box.from_centerleft(
                .{ end_of_text, box.botleft[1] + box.size[1]/2 },
                .{ ctx.pixels(3), box.size[1] * 0.9 });
            ctx.draw_rect(cursor_box.botleft, cursor_box.size, .from_u32(0x7f7f7fff));
        }

        if (input.dirty)
            input.dirty_t += ctx.get_delta_time();
    } 

    fn scroll_box(ctx: *UIContext, box: Box, scroll: *Scroll, scroll_h: f32) void {
        // const ui = ctx.user_data;
        const dt = ctx.get_delta_time();
        const scroll_bar_w = @max(0.02, ctx.pixels(20));
        const scroll_bar_h = (box.size[1] / scroll_h) * box.size[1];
        const scroll_bar = Box {
            .botleft = .{ box.x_right()-scroll_bar_w, box.y_top() - scroll.scroll*box.size[1]-scroll_bar_h },
            .size =.{ scroll_bar_w, scroll_bar_h },
        };
        if (scroll_h <= box.size[1]) return;
        // Scroll bar background
        ctx.draw_rect(.{ box.x_right()-scroll_bar_w, box.botleft[1] }, .{ scroll_bar_w, box.size[1] }, .from_u32(0x7f7f7fdf));
        // Scroll bar itself
        ctx.draw_rect(
            scroll_bar.botleft,
            scroll_bar.size,
            .from_u32(0x3f3f3fff));
        

        // update scroll from inputs
        if (mouse_within_rect(ctx, scroll_bar)) {
            scroll.clicked = c.RGFW_isMousePressed(c.RGFW_mouseLeft) == 1 or scroll.clicked;
        }

        if (scroll.clicked) {
            scroll.scroll += ctx.mouse_delta[1]/box.size[1]; 
            ctx.draw_rect(scroll_bar.botleft, scroll_bar.size, .from_u32(0x00000030));
            ctx.draw_rect_lines(
                scroll_bar.botleft,
                scroll_bar.size,
                2,
                .{ .r = 0xff, .g = 0xff, .b = 0, .a = 0xdf },
            );
            if (c.RGFW_isMouseReleased(c.RGFW_mouseLeft) == 1) scroll.clicked = false;
        } else {
            ctx.draw_rect_lines(
                scroll_bar.botleft,
                scroll_bar.size,
                2,
                .from_u32(0xffffffdf),
            );
        }
        // ctx.draw_text(.{0, 0}, 1, ctx.input_chars.items, .white);

        if (gl.c.RGFW_isKeyDown(gl.c.RGFW_up) == 1) scroll.scroll -= scroll_spd * dt / scroll_h;
        if (gl.c.RGFW_isKeyDown(gl.c.RGFW_down) == 1) scroll.scroll += scroll_spd * dt / scroll_h;
        scroll.scroll -= ctx.mouse_scroll[1] * dt * 10 * scroll_spd / scroll_h;
        scroll.scroll = std.math.clamp(scroll.scroll, 0, (scroll_h-box.size[1])/scroll_h);

    }

    fn within_rect(p: Vec2, box: Box) bool {
        const botleft = box.botleft;
        const size = box.size;
        return p[0] >= botleft[0] and p[1] >= botleft[1]
            and p[0] <= botleft[0] + size[0] and p[1] <= botleft[1] + size[1];
    }

    fn mouse_within_rect(ctx: *UIContext, box: Box) bool {
        return within_rect(ctx.mouse_pos_gl, box);
    }

    fn repeat(ui: *UI, dt: f32) u32 {
        var ct: u32 = 0;
        ui.repeat_t += dt;
        while (ui.repeat_t >= 1.0/repeat_rate) {
            ui.repeat_t -= 1.0/repeat_rate;
            ct += 1;
        }
        return ct;
    }

    // fn highlight_on_hover(ctx: *UIContext, box: Box) void {
    //     if (mouse_within_rect)
    // }
};


pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    // defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    err_text_arena = std.heap.ArenaAllocator.init(gpa);

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    std.log.debug("init database.", .{});
    var db = try Sqlite.init("feed.db");
    defer db.deinit();
   
    var db_worker_t = try std.Thread.spawn(.{}, db_worker, .{ &db, gpa });

    var ui = UI { .gpa = gpa, .posts = try db.get_posts_all(gpa), .channels = try db.get_channels_all(gpa), .db = &db };
    ui.reset_display_post_to_default();

    var ctx: UIContext = undefined;
    try UIContext.init(&ctx, &ui, UI.render, "ui demo", 1920, 1024, gpa);
    std.log.info("posts: {}, channels: {}", .{ ui.posts.len, ui.channels.len });
    while (!ctx.window_should_close()) {
        ctx.render();
    }

    ctx.close_window();

    should_quit = true;

    db_cond.signal();
    db_worker_t.join();
}

test {
    _ = std.testing.refAllDeclsRecursive(parser);
}
