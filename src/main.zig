const std = @import("std");
const log = std.log;
const xml = @import("xml");
const Sqlite = @import("sqlite.zig");
const parser = @import("xml_parser.zig");

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

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len != 2) {
        return error.InvalidArguments; // usage: reader file
    }
    const url = args[1];

    std.log.debug("init database.", .{});
    var db = try Sqlite.init("feed.db");
    defer db.deinit();
    

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

    
    const channel = try parse_rss_buf(fetch_sink.written(), gpa, arena.allocator());
    std.debug.print("Channel: {s}\n{s}\n{s}\n", .{ channel.title, channel.link, channel.description });
    std.debug.print("Channel extra: {s}\n", .{ channel.language });
    for (channel.item) |item| {
        std.debug.print("item {s}\n", .{item.title});
    }

    try db.add_posts(channel);
}

test {
    _ = std.testing.refAllDeclsRecursive(parser);
}
