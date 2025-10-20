const std = @import("std");
const log = std.log;
const xml = @import("xml");
const parser = @import("xml_parser.zig");

const assert = std.debug.assert;
const fatal = std.process.fatal;
const Allocator = std.mem.Allocator;

const Item = struct {
    title: []const u8,
    pubDate: []const u8,
    link: []const u8,
    guid: []const u8,
    description: []const u8,
};

const Channel = struct {
    title: []const u8,
    link: []const u8,
    description: []const u8,
    language: []const u8 = "",
    item: []Item,
};

fn parse_rss(reader: *std.Io.Reader, gpa: Allocator, arena: Allocator) !Channel {
    var streaming_reader: xml.Reader.Streaming = .init(gpa, reader, .{});
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
    try parser.expect_element_end_name(xml_reader, "rss");
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
    // var stdout_buf: [4096]u8 = undefined;
    // var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    // const stdout = &stdout_writer.interface;

    
    const input_path = args[1];
    var input_file = try std.fs.cwd().openFile(input_path, .{});
    defer input_file.close();
    var input_buf: [4096]u8 = undefined;
    var input_reader = input_file.reader(&input_buf);
    const channel = try parse_rss(&input_reader.interface, gpa, arena.allocator());
    std.debug.print("Channel: {s}\n{s}\n{s}\n", .{ channel.title, channel.link, channel.description });
    std.debug.print("Channel extra: {s}\n", .{ channel.language });
    for (channel.item) |item| {
        std.log.info("item {s}", .{item.title});
    }
}

test {
    _ = std.testing.refAllDeclsRecursive(parser);
}
