const std = @import("std");
const sqlite = @import("sqlite");
const Sqlite = @This();

const time = @cImport({
    @cInclude("thirdparty/strptime/LibOb_strptime.h");
});

const Ds = @import("main.zig");

db: sqlite.Db,

pub fn init(path: [:0]const u8) !Sqlite {
    var res = Sqlite{ .db = undefined };

    res.db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = path },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });
    const schema = @embedFile("schema.sql");
    var diag = sqlite.Diagnostics {};
    res.db.execMulti(schema, .{ .diags = &diag }) catch |e| {
        std.log.err("{}: {f}", .{ e, diag });
    };

    return res;
}

pub fn deinit(self: *Sqlite) void {
    self.db.deinit();
}

const known_time_formats = [_][:0]const u8 {
     "%d %b %Y %H:%M:%S %Z",
     "%a, %d %b %Y %H:%M:%S %Z",
};
fn convert_time_format(s: [:0]const u8) ?time.tm {
    var time_zone = time.LibOb_localTimeZone(0);
    for (known_time_formats) |time_format| {
        // _ = time_format;
        var tm = time.tm {};
        const convert_result = 
        time.LibOb_strptime(s, time_format, &tm, &time_zone);
        if (convert_result != null) return tm;
        // std.log.warn("year: {}, month: {}, day: {}, {}", .{ tm.tm_year+1900, tm.tm_mon+1, tm.tm_mday, tm.tm_wday });
    }
    return null;
}

pub fn add_posts(self: *Sqlite, channel: Ds.Channel) !void {
    const q =
        \\INSERT INTO channel (link, title, description)
        \\VALUES (?, ?, ?)
        \\ON CONFLICT(link) DO UPDATE SET
        \\    title = excluded.title,
        \\    description = excluded.description
        \\RETURNING rowid;
                ;
    var stmt = try self.db.prepare(q);
    const channel_id = try stmt.one(u64, .{}, .{ channel.link, channel.title, channel.description })
        orelse unreachable;
    stmt.deinit();

    std.log.debug("channel row id: {}", .{ channel_id });

    var savepoint = try self.db.savepoint("items");
    defer savepoint.rollback();

    const q2 = 
        \\INSERT INTO post
        \\  (title, pubdate, link, description, read, channel)
        \\  values (?, ?, ?, ?, ?, ?)
        \\    ON CONFLICT(link) DO UPDATE SET
        \\      title = excluded.title,
        \\      pubdate = excluded.pubdate,
        \\      description = excluded.description
        ;
    var stmt2 = try self.db.prepare(q2);
    
    for (channel.item) |item| {
        const time_stamp: time.time_t = blk: {
            var tm = convert_time_format(item.pubDate) orelse {
                std.log.err("Cannot strptime {s}", .{ item.pubDate});
                break :blk 0;
            };
            std.log.debug("year: {}, month: {}, day: {}, wday: {}", .{ 
                tm.tm_year+1900, tm.tm_mon+1, tm.tm_mday, tm.tm_wday });
            // std.log.info("converted from: {s}", .{ item.pubDate });
            break :blk time.mktime(&tm);
        };
        
        stmt2.reset();
        try stmt2.exec(.{}, .{
            item.title,
            time_stamp,
            item.link,
            item.description,
            false,
            channel_id,
        });
    }
    savepoint.commit();
}


// test "time convert" {
//     var time_zone = time.LibOb_localTimeZone(0);
//     var tm = time.tm {};
//     const time_format = "";
//     const convert_result = 
//         time.LibOb_strptime(s, time_format, &tm, &time_zone);
//     try std.testing.expect(convert_result != null);
// 
// }
