const std = @import("std");
const log = std.log;
const xml = @import("xml");

const assert = std.debug.assert;
const fatal = std.process.fatal;
const Allocator = std.mem.Allocator;

const XmlError = xml.Reader.ReadError || error { 
    UnexpectedNode,
    UnexpectedElementName,
};

const XmlParserError = XmlError || error {
    DuplicateField,
    UnsetField,
    OutOfMemory,
};

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

fn ParseState(comptime info: std.builtin.Type.Struct) type {
    var type_array: [info.fields.len]type = undefined;
    inline for (&type_array, info.fields) |*el, f| {
        el.* = if (!is_non_str_slice(f.type)) bool else std.ArrayList(std.meta.Child(f.type));
    }
    return std.meta.Tuple(&type_array);
}

fn parse_state(comptime info: std.builtin.Type.Struct) ParseState(info) {
    var res: ParseState(info) = undefined;
    // @compileLog(@typeName(ParseState(info)));
    inline for (info.fields, &res) |f, *r| {
        if (comptime !is_non_str_slice(f.type)) {
            r.* = false;
        } else {
            r.* = .empty;
        }
    }
    return res;
}

fn is_non_str_slice(comptime T: type) bool {
    if (T == []const u8 or T == []u8) return false;
    const info = @typeInfo(T);
    return switch (info) {
        .pointer => |ptr| ptr.size == .slice,
        else => false,
    };
}


pub fn parse_struct(comptime T: type, reader: *xml.Reader, maybe_start_el_name: ?[]const u8, str_alloc: Allocator) XmlParserError!T {
    const info = @typeInfo(T);
    if (info != .@"struct")
        @compileError("Expect T to be a struct, got " ++ @typeName(T));
    const struct_info = info.@"struct";

    // if (maybe_start_el_name) |start_el_name| {
    //     try expect_element_start_name(reader, start_el_name);
    // } 

    var res: T = undefined;
    var field_states = parse_state(struct_info);
    var arena = std.heap.ArenaAllocator.init(str_alloc);
    defer arena.deinit();
    while (reader.read()) |node| {
        switch (node) {
            .text => continue,
            .element_start => {},
            // This is the exit point of the while loop, as well as the function
            .eof,
            .element_end => {
                if (node == .element_end)
                    if (maybe_start_el_name) |start_el_name| {
                        if (!std.mem.eql(u8, reader.elementName(), start_el_name)) {
                            std.log.err("Unexpected Element End Tag: {s} {s}", .{reader.elementName(), start_el_name});
                            return XmlParserError.UnexpectedElementName;   
                        }
                    } else {
                        return XmlError.UnexpectedNode;
                    };
                inline for (struct_info.fields, &field_states) |f, *state| {
                    if (comptime is_non_str_slice(f.type)) {
                        @field(res, f.name) = try state.toOwnedSlice(str_alloc); 
                    } else if (f.type == []const u8) {
                        if (!state.*)
                            @field(res, f.name) = f.defaultValue() orelse 
                                return XmlParserError.UnsetField;

                    }
                }
                return res;
            },
            else => return XmlError.UnexpectedNode,
        }
        const name = try arena.allocator().dupe(u8, reader.elementName());
        // std.log.debug("element start name: {s}", .{name});
        inline for (struct_info.fields, &field_states) |f, *state| {
            if (std.mem.eql(u8, name, f.name)) {
                
                if (comptime is_non_str_slice(f.type)) {
                    // std.log.debug("sub: {s}", .{name});
                    
                    const sub_el = try parse_struct(std.meta.Child(f.type), 
                        reader, name, str_alloc);
                    try state.append(str_alloc, sub_el); 
                    break;
                } else if (f.type == []const u8) {
                    if (state.*)
                        return XmlParserError.DuplicateField;
                    state.* = true;
                    @field(&res, f.name) = try reader.readElementTextAlloc(str_alloc);
                    // try expect_element_end_name(reader, f.name);
                    break;
                }
            }
        } else {
            std.log.debug("Unknown field encounter: {s}", .{ name });
            try skip_until_el_end(reader, name);
            _ = arena.reset(.retain_capacity);
        }
    } else |e| return e;
    unreachable;
}

pub fn parse_slice_of(comptime T: type, reader: *xml.Reader, item_name: []const u8, str_alloc: Allocator) XmlParserError![]T {
    var list = std.ArrayList(T).empty;
    const el = try parse(T, reader, item_name, str_alloc); 
    try list.append(str_alloc, el);
}

pub fn parse(comptime T: type, reader: *xml.Reader, maybe_start_el_name: ?[]const u8, str_alloc: Allocator) XmlParserError!T {
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => return parse_struct(T, reader, maybe_start_el_name, str_alloc),
        .pointer => |pointer| {
            switch (pointer.size) {
                .slice => return parse_slice_of(pointer.child, reader, maybe_start_el_name, str_alloc),
                else => @compileError("Unsupported"),
            }
        },
        else => @compileError("Unsupported"),
    }
}

fn skip_until_el_end(reader: *xml.Reader, el_end_name: []const u8) XmlError!void {
    var stack: i32 = 1;
    while (reader.read()) |node| {
        switch (node) {
            .eof => break,
            .element_start => stack += 1,
            .element_end => {
                stack -= 1;
                if (stack == 0 and std.mem.eql(u8, reader.elementName(), el_end_name)) {
                    return;
                }
            },
            else => {},
        }
    } else |e| return e;
    return XmlError.UnexpectedNode;
}

pub fn expect_next(reader: *xml.Reader, expected: xml.Reader.Node) XmlError!void {
    // std.log.debug("expect {}", .{ expected });
    while (reader.read()) |node| {
        // std.log.debug("node: {}", .{node});
        if (node == expected) return;
        if (node == .text) continue; 
        return XmlError.UnexpectedNode;
    } else |e| return e;
}

pub fn expect_element_start_name(reader: *xml.Reader, name: []const u8) XmlError!void {
    // std.log.debug("expect {}", .{ expected });
    try expect_next(reader, .element_start); 
    if (!std.mem.eql(u8, reader.elementName(), name)) return XmlError.UnexpectedElementName;
}

pub fn expect_element_end_name(reader: *xml.Reader, name: []const u8) XmlError!void {
    // std.log.debug("expect {}", .{ expected });
    try expect_next(reader, .element_end); 
    // std.log.infop("end: {s}", .{ reader.elementName() });
    if (!std.mem.eql(u8, reader.elementName(), name)) return XmlError.UnexpectedElementName;
}

pub fn expect_next_no_skip_text(reader: *xml.Reader, expected: xml.Reader.Node) XmlError!void {
    const node = try reader.read();
    if (node != expected) return error.UnexpectedNode;
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len != 2) {
        return error.InvalidArguments; // usage: reader file
    }
    
    const input_path = args[1];
    var input_file = try std.fs.cwd().openFile(input_path, .{});
    defer input_file.close();
    var input_buf: [4096]u8 = undefined;
    var input_reader = input_file.reader(&input_buf);
    var streaming_reader: xml.Reader.Streaming = .init(gpa, &input_reader.interface, .{});
    defer streaming_reader.deinit();
    const reader = &streaming_reader.interface;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    
    try expect_next(reader, .xml_declaration); 
    try stdout.print("xml_declaration: version={s} encoding={?s} standalone={?}\n", .{
        reader.xmlDeclarationVersion(),
        reader.xmlDeclarationEncoding(),
        reader.xmlDeclarationStandalone(),
    });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    try expect_element_start_name(reader, "rss");
    // try expect_element_start_name(reader, "channel");
    try expect_element_start_name(reader, "channel");
    const channel = try parse_struct(Channel, reader, "channel", arena.allocator()); 
    try expect_element_end_name(reader, "rss");

    try stdout.print("Channel: {s}\n{s}\n{s}\n", .{ channel.title, channel.link, channel.description });
    try stdout.print("Channel extra: {s}\n", .{ channel.language });
    for (channel.item) |item| {
        std.log.info("item {s}", .{item.title});
    }

    try stdout.flush();
}


test "struct parse" {
    const xml_buf = \\<?xml version="1.0" encoding="utf-8"?>
                    \\<rss>
                    \\    <a>Hello A</a>
                    \\    <b>Hello B</b> 
                    \\</rss>
                    ;
    const S = struct {
        a: []const u8,
        b: []const u8,
    };
    const ta = std.testing.allocator;
    var streaming_reader: xml.Reader.Static = .init(ta, xml_buf, .{});
    defer streaming_reader.deinit();
    const reader = &streaming_reader.interface;

    try expect_next(reader, .xml_declaration);
    try expect_element_start_name(reader, "rss");
    const s = try parse_struct(S, reader, "rss", ta);
    try std.testing.expectEqualDeep(s, S { .a = "Hello A", .b = "Hello B" });
    ta.free(s.a);
    ta.free(s.b);
}

test "struct parse unknown field" {
    const xml_buf = \\<?xml version="1.0" encoding="utf-8"?>
                    \\<rss>
                    \\    <a>Hello A</a>
                    \\    <b>Hello B</b> 
                    \\    <c>Hello C</c>
                    \\</rss>
                    ;
    const S = struct {
        a: []const u8,
        b: []const u8,
    };
    const ta = std.testing.allocator;
    var streaming_reader: xml.Reader.Static = .init(ta, xml_buf, .{});
    defer streaming_reader.deinit();
    const reader = &streaming_reader.interface;

    try expect_next(reader, .xml_declaration);
    try expect_element_start_name(reader, "rss");
    const s = try parse_struct(S, reader, "rss", ta);
    try std.testing.expectEqualDeep(s, S { .a = "Hello A", .b = "Hello B" });
    ta.free(s.a);
    ta.free(s.b);
}
