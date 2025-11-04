const std = @import("std");
const log = std.log;

const xml = @import("xml");

const Sqlite = @import("sqlite.zig");
const parser = @import("xml_parser.zig");

const gl = @import("gl");
const Vec2 = gl.Vec2;
const c = gl.c;

const RGBA = gl.RGBA;

const bg_color = RGBA.from_u32(0x303030ff);


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

// Only one channel is supported
fn parse_rss(reader: *std.Io.Reader, gpa: Allocator, arena: Allocator) !Channel {
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
fn parse_rss_buf(buf: []const u8, gpa: Allocator, arena: Allocator) !Channel {
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

fn fetch_rss_and_update(url: []const u8, db: *Sqlite, gpa: Allocator, arena: Allocator) !void {
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
var db_err_str: []const u8 = "";
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
        fetch_rss_and_update(db_rss_url, db, gpa, arena.allocator()) catch |e| {
            db_err_str = @errorName(e);
        };
        db_fetch_complete.store(true, .release);
        
    }
}

const UIContext = gl.Context(UI);
const UI = struct {
    const scroll_spd = 0.5;
    gpa: Allocator,

    main_scroll: Scroll = .{ .scroll = 0, .clicked = false },
    input: Input = .{},

    db: *Sqlite,
    posts: []Item,
    channels: [][]const u8,
    
    // const titles: []const []const u8 = &.{ "Title A", "Title B" };
    pub const Scroll = struct {
        scroll: f32,
        clicked: bool,
    };

    pub const Input = struct {
        content: std.ArrayList(u8) = .empty,
        focused: bool = false,
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
    };

    fn render(ctx: *UIContext) void {
        const ui = ctx.user_data;
        // const dt = ctx.get_delta_time();

        ctx.clear(bg_color);
        const left_box = Box { .botleft = .{ ctx.x_left(), ctx.y_bot() }, .size = .{ 0.3, ctx.screen_h()-0.1 } };
        const btn_h = ctx.cal_font_h(0.5) * 2;

        ctx.begin_scissor_gl_coord(left_box.botleft, left_box.size);
        for (ui.channels, 1..) |channel_title, i| {
            const if32: f32 = @floatFromInt(i);
            if (button(
                    ctx,
                    .{ ctx.x_left(), left_box.y_top()-if32*btn_h }, 
                    .{ 0.3, btn_h },
                    0.5,
                    channel_title)) {
                // std.log.debug("Cliekd", .{}); 
                // ui.selected_title = channel_title;
            }
        }
        const plus_size = ctx.get_char_size(1, '+');
        const add_btn_side = btn_h;
        const top_menu_y_center = ctx.y_top()-add_btn_side/2.0-0.015;
        const add_box = Box.from_centerleft(.{ ctx.x_left()+0.01, top_menu_y_center }, .{ add_btn_side, add_btn_side });
        ctx.end_scissor();

        if (button_ex(ctx, add_box.botleft, add_box.size, 1, "+",
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

        if (db_fetch_complete.load(.acquire)) {
            ui.posts = ui.db.get_posts_all(ui.gpa) catch unreachable;
            ui.channels = ui.db.get_channels_all(ui.gpa) catch unreachable;
        }
        
        input_box(ctx,
            .from_centerleft(.{ add_box.x_right() + 0.01, top_menu_y_center }, .{ 1, add_btn_side }),
            &ui.input, "Enter url of rss here...", ui.gpa);
        // ctx.draw_text(.{ ctx.x_left()+add_btn_side+0.05, ctx.y_top()-(add_btn_side+ctx.cal_font_h(0.5))/2-0.015}, 0.5, ui.input.items, .white);
        // ctx.draw_rect(.{ add_btn_pos[0]+(add_btn_size[0]-plus_size[0])/2, add_btn_pos[1]+(add_btn_size[1]-plus_size[1])/2 }, plus_size,.white);

        const titles_h = @as(f32, @floatFromInt(ui.posts.len)) * btn_h;

        // ctx.draw_rect_lines(.{ ctx.x_left(), ctx.y_bot() }, .{ 0.3, ctx.screen_h() }, 5, .from_u32(0xffffff30));

        const main_box = Box { .botleft = .{ ctx.x_left()+0.3, ctx.y_bot() }, .size = .{ ctx.screen_w()-0.3, ctx.screen_h()-0.1 } };
        ctx.begin_scissor_gl_coord(main_box.botleft, main_box.size);
        for (ui.posts, 1..) |post, i| {
            const if32: f32 = @floatFromInt(i);
            if (button(
                    ctx,
                    .{ main_box.botleft[0], main_box.top(0)-if32*btn_h + ui.main_scroll.scroll*titles_h }, 
                    .{  ctx.screen_w()-0.3, btn_h },
                    0.5,
                    post.title)) {
                // std.log.debug("Cliekd", .{}); 
            }
        }
        ctx.end_scissor();

        scroll_box(ctx, main_box, &ui.main_scroll, titles_h);
        ctx.draw_rect_lines(main_box.botleft, main_box.size, 1, .yellow);
        // std.log.info("Mouse gl pos: {any} {any}", .{ctx.mouse_pos_gl, ctx.mouse_pos_screen});
        // std.log.info("Mouse scroll: {any}", .{ctx.mouse_scroll});
    }

    // retunr true if hovered
    fn button_ex(ctx: *UIContext, botleft: Vec2, size: Vec2, font_size: f32, text: []const u8, text_offset: Vec2) bool {
        const within = within_rect(ctx.mouse_pos_gl, .{ .botleft = botleft, .size = size });
        if (within) {
            if (gl.c.RGFW_isMouseDown(gl.c.RGFW_mouseLeft) == 1)
                ctx.draw_rect(botleft, size, .from_u32(0x00000030))
            else
                ctx.draw_rect(botleft, size, .from_u32(0xffffff30));
        }
        // const yoffset = 0.1*ctx.cal_font_h(0.5);
        // ctx.draw_rect(botleft, size,.from_u32(0xffffff30));
        ctx.draw_text(.{ botleft[0] + text_offset[0], botleft[1] + text_offset[1] }, font_size, text, .white);
        // ctx.draw_rect_lines(.{ botleft[0] + text_offset[0], botleft[1] + text_offset[1] }, size, 1, .{ .r = 0xff, .a = 0x7f });
        ctx.draw_rect_lines(botleft, size, 5, .from_u32(0xffffff30));
        return within and gl.c.RGFW_isMouseReleased(gl.c.RGFW_mouseLeft) == 1;
    }
    fn button(ctx: *UIContext, botleft: Vec2, size: Vec2, font_size: f32, text: []const u8) bool {
        const text_offset = Vec2 { ctx.pixels(5), (size[1]-ctx.cal_font_h(font_size))/2 };
        return button_ex(ctx, botleft, size, font_size, text, text_offset);
    }

    fn input_box(ctx: *UIContext, box: Box, input: *Input, hint_text: []const u8, a: Allocator) void {
        const font_size = 0.5;
        ctx.draw_rect(box.botleft, box.size, .white); 
        const text_offset = Vec2 { ctx.pixels(5), (box.size[1]-ctx.cal_font_h(font_size))/2 };
        if (input.content.items.len > 0)
            ctx.draw_text(.{ box.botleft[0] + text_offset[0], box.botleft[1] + text_offset[1] }, font_size, input.content.items, .black)
        else
            ctx.draw_text(.{ box.botleft[0] + text_offset[0], box.botleft[1] + text_offset[1] }, font_size, hint_text, .from_u32(0x7f7f7fff));


        if (ctx.mouse_left)
            input.focused = mouse_within_rect(ctx, box);

        if (input.focused) {
            ctx.draw_rect_lines(box.botleft, box.size, 5, .yellow);
            input.content.appendSlice(a, ctx.input_chars.items) catch unreachable;
            if (gl.c.RGFW_isKeyPressed(gl.c.RGFW_backSpace) == 1 and input.content.items.len > 0)
                input.content.shrinkRetainingCapacity(input.content.items.len-1);
            if (ctx.is_paste) {
                const buf = ctx.clipboard();
                std.log.debug("PASTE {s} {}", .{ buf, buf.len });
                input.content.appendSlice(a, buf) catch unreachable;
            }
        } 
        
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

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    std.log.debug("init database.", .{});
    var db = try Sqlite.init("feed.db");
    defer db.deinit();
   
    var db_worker_t = try std.Thread.spawn(.{}, db_worker, .{ &db, gpa });

    var ui = UI { .gpa = gpa, .posts = try db.get_posts_all(gpa), .channels = try db.get_channels_all(gpa), .db = &db };
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
