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
    WriteFailed,
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
    const info = @typeInfo(T);
    return switch (info) {
        .pointer => |ptr|
            switch (ptr.size) {
                .slice => ptr.child != u8,
                else => false,
        },
        else => false,
    };
}

fn is_str_slice(comptime T: type) bool {
    const info = @typeInfo(T);
    return switch (info) {
        .pointer => |ptr|
            switch (ptr.size) {
                .slice => ptr.child == u8,
                else => false,
        },
        else => false,
    };

}

/// Parse the xml and tries to match elements to struct field
/// The only valid fields inside the struct are: 
/// []const u8
/// []S, where is `S` is some struct that is valid
///
/// Memory is allocated for copying strings and creating slices.
pub fn parse_struct(comptime T: type, reader: *xml.Reader, maybe_start_el_name: ?[]const u8, str_alloc: Allocator) XmlParserError!T {
    if (maybe_start_el_name) |start_el_name| {
        try expect_element_start_name(reader, start_el_name);
    }
    return parse_struct_inner(T, reader, maybe_start_el_name, str_alloc);
}

fn parse_struct_inner(comptime T: type, reader: *xml.Reader, maybe_start_el_name: ?[]const u8, str_alloc: Allocator) XmlParserError!T {
    const info = @typeInfo(T);
    if (info != .@"struct")
        @compileError("Expect T to be a struct, got " ++ @typeName(T));
    const struct_info = info.@"struct";

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
                    } else if (is_str_slice(f.type)) {
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
                    
                    const sub_el = try parse_struct_inner(std.meta.Child(f.type), 
                        reader, name, str_alloc);
                    try state.append(str_alloc, sub_el); 
                    break;
                } else if (is_str_slice(f.type)) {
                    if (state.*)
                        return XmlParserError.DuplicateField;
                    state.* = true;
                    const text = try reader.readElementText();
                    @field(&res, f.name) = try str_alloc.dupeZ(u8, text);
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

pub fn skip_until_el_end(reader: *xml.Reader, el_end_name: []const u8) XmlError!void {
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

test "struct parse basic" {
    const xml_buf = \\<?xml version="1.0" encoding="utf-8"?>
                    \\<rss>
                    \\    <a>Hello A</a>
                    \\    <b>Hello B</b> 
                    \\    <c />
                    \\    <d></d>
                    \\</rss>
                    ;
    const S = struct {
        a: []const u8,
        b: []const u8,
        c: []const u8,
        d: []const u8,
    };
    const ta = std.testing.allocator;
    var streaming_reader: xml.Reader.Static = .init(ta, xml_buf, .{});
    defer streaming_reader.deinit();
    const reader = &streaming_reader.interface;

    try expect_next(reader, .xml_declaration);
    const s = try parse_struct(S, reader, "rss", ta);
    try std.testing.expectEqualDeep(s, S { .a = "Hello A", .b = "Hello B", .c = "", .d = "" });
    ta.free(s.a);
    ta.free(s.b);
}

test "struct parse slice" {
    const xml_buf = \\<?xml version="1.0" encoding="utf-8"?>
                    \\<rss>
                    \\    <a>
                    \\      <child>i am children 1</child>
                    \\    </a>
                    \\    <a>
                    \\      <child>i am children 2</child>
                    \\    </a>
                    \\    <b>not a slice</b>
                    \\</rss>
                    ;
    const Child = struct {
        child: []const u8
    };
    const S = struct {
        a: []const Child,
        b: []const u8,
    };
    const ta = std.testing.allocator;
    var streaming_reader: xml.Reader.Static = .init(ta, xml_buf, .{});
    defer streaming_reader.deinit();
    const reader = &streaming_reader.interface;

    try expect_next(reader, .xml_declaration);
    const s = try parse_struct(S, reader, "rss", ta);
    try std.testing.expectEqualDeep(s, S { .a = &.{ .{ .child = "i am children 1" }, .{ .child = "i am children 2"} }, .b = "not a slice" });
    ta.free(s.a[0].child);
    ta.free(s.a[1].child);
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
    const s = try parse_struct(S, reader, "rss", ta);
    try std.testing.expectEqualDeep(s, S { .a = "Hello A", .b = "Hello B" });
    ta.free(s.a);
    ta.free(s.b);
}
