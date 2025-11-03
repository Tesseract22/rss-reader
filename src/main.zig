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

const UIContext = gl.Context(UI);
const UI = struct {
    const scroll_spd = 0.5;
    gpa: Allocator,
    selected_title: []const u8 = "",
    main_scroll: f32 = 0,
    posts: []Item,
    
    // const titles: []const []const u8 = &.{ "Title A", "Title B" };
    pub const ScrollBox = struct {
        botleft: Vec2,
        size: Vec2,
        scroll: f32
    };
    const Box = struct {
        botleft: Vec2,
        size: Vec2,

        pub fn x_right(self: Box) f32 {
            return self.botleft[0] + self.size[0]; 
        }
    };

    fn render(ctx: *UIContext) void {
        const ui = ctx.user_data;
        const dt = ctx.get_delta_time();

        ctx.clear(bg_color);
        const btn_h = ctx.cal_font_h(0.5) * 2;
        // for (titles, 1..) |title, i| {
        //     const if32: f32 = @floatFromInt(i);
        //     if (button(
        //             ctx,
        //             .{ ctx.x_left(), ctx.y_top()-if32*btn_h }, 
        //             .{ 0.3, btn_h },
        //             0.5,
        //             title)) {
        //         // std.log.debug("Cliekd", .{}); 
        //         ui.selected_title = title;
        //     }
        // }
        const titles_h = @as(f32, @floatFromInt(ui.posts.len)) * btn_h;

        ctx.draw_rect_lines(.{ ctx.x_left(), ctx.y_bot() }, .{ 0.3, ctx.screen_h() }, 5, .from_u32(0xffffff30));

        for (ui.posts, 1..) |post, i| {
            const if32: f32 = @floatFromInt(i);
            if (button(
                    ctx,
                    .{ ctx.x_left()+0.3, ctx.y_top()-if32*btn_h+ui.main_scroll }, 
                    .{  ctx.screen_w()-0.3, btn_h },
                    0.5,
                    post.title)) {
                // std.log.debug("Cliekd", .{}); 
                ui.selected_title = post.title;
            }
        }

        const main_box = Box { .botleft =. { ctx.x_left()+0.3, ctx.y_bot() }, .size = .{ ctx.screen_w()-0.3, ctx.screen_h() } };
        scroll_box(ctx, main_box, &ctx.main_scroll, titles_h);
        // std.log.info("Mouse gl pos: {any} {any}", .{ctx.mouse_pos_gl, ctx.mouse_pos_screen});
        // std.log.info("Mouse scroll: {any}", .{ctx.mouse_scroll});
    }

    // retunr true if hovered
    fn button(ctx: *UIContext, botleft: Vec2, size: Vec2, font_size: f32, text: []const u8) bool {
        const within = within_rect(ctx.mouse_pos_gl, .{ .botleft = botleft, .size = size });
        if (within) {
            ctx.draw_rect(botleft, size, .from_u32(0xffffff30));
        }
        // const yoffset = 0.1*ctx.cal_font_h(0.5);
        ctx.draw_text(.{ botleft[0], botleft[1] + (size[1]-ctx.cal_font_h(font_size))/2 }, font_size, text, .white);
        ctx.draw_rect_lines(botleft, size, 5, .from_u32(0xffffff30));
        return within and ctx.mouse_left;
    }

    fn scroll_box(ctx: *UIContext, box: Box, scroll: *f32, scroll_h: f32) void {
        // const ui = ctx.user_data;
        const dt = ctx.get_delta_time();
        const scroll_bar_w = 0.02;
        const scroll_bar_h = (box.size[1] / scroll_h) * box.size[1];
        const scroll_bar = Box {
            .botleft = .{ box.x_right()-scroll_bar_w, box.y_top() - scroll.*/scroll_h*ctx.screen_h()-scroll_bar_h },
            .size =.{ scroll_bar_w, scroll_bar_h },
        };
        // Scroll bar background
        ctx.draw_rect(.{ box.x_right()-scroll_bar_w, box.y_bot() }, .{ scroll_bar_w, box.size[1] }, .from_u32(0x7f7f7fdf));
        // Scroll bar itself
        ctx.draw_rect(
            scroll_bar.botleft,
            scroll_bar.size,
            .from_u32(0x3f3f3fff));

        if (mouse_within_rect(ctx, scroll_bar) and c.RGFW_isMouseDown(c.RGFW_mouseLeft) == 1) {
            scroll.* += ctx.mouse_delta[1]*scroll_h/box.size(); 
        }
        // ctx.draw_text(.{0, 0}, 1, ctx.input_chars.items, .white);

        if (gl.c.RGFW_isKeyDown(gl.c.RGFW_up) == 1) scroll.* -= scroll_spd * dt;
        if (gl.c.RGFW_isKeyDown(gl.c.RGFW_down) == 1) scroll.* += scroll_spd * dt;
        scroll.* -= ctx.mouse_scroll[1] * dt * 10;
        scroll.* = std.math.clamp(scroll.*, 0, scroll_h-box.size[1]);

    }

    fn within_rect(p: Vec2, box: Box) bool {
        const botleft = box.botleft;
        const size = box.size;
        return p[0] >= botleft[0] and p[1] >= botleft[1]
            and p[0] <= botleft[0] + size[0] and p[1] <= botleft[1] + size[1];
    }

    fn mouse_within_rect(ctx: UIContext, box: Box) bool {
        return within_rect(ctx.mouse_pos_gl, box);
    }
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
    

    var ui = UI { .gpa = gpa, .posts = try db.get_posts_all(gpa) };
    var ctx: UIContext = undefined;
    try UIContext.init(&ctx, &ui, UI.render, "ui demo", 1920, 1024, gpa);
    std.log.info("posts: {}", .{ ui.posts.len });
    while (!ctx.window_should_close()) {
        ctx.render();
    }

    ctx.close_window();


}

test {
    _ = std.testing.refAllDeclsRecursive(parser);
}
