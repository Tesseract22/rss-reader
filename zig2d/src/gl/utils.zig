const std = @import("std");

pub const Vec2 = [2]f32;
pub const Vec3 = [3]f32;
pub const Vec4 = [4]f32;

pub const Vec2u = [2]u32;
pub const Vec3u = [3]u32;

pub const Vec2i = [2]i32;


pub fn v2add(a: Vec2, b: Vec2) Vec2 {
    return .{ a[0] + b[0], a[1] + b[1] };
}

pub fn v2sub(a: Vec2, b: Vec2) Vec2 {
    return .{ a[0] - b[0], a[1] - b[1] };
}

pub fn v2scal(a: Vec2, b: f32) Vec2 {
    return .{ a[0] * b , a[1] * b };
}

// pub fn v2pixels(a: Vec2) Vec2 {
//     return .{ ctx.pixels(a[0]), ctx.pixels(a[1]) };
// }

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
