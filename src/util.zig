const std = @import("std");

pub const Vec3 = packed struct {
    x: f32,
    y: f32,
    z: f32,
};

pub const Vec2 = packed struct {
    x: f32,
    y: f32,
};

pub const iVec3 = struct {
    x: i32,
    y: i32,
    z: i32,

    pub fn hash(self: *iVec3) u64 {
        return std.hash.Wyhash.hash(69, @as([*]const u8, @ptrCast(self))[0..@sizeOf(iVec3)]);
    }
};

pub fn newVec3(x: f32, y: f32, z: f32) Vec3 {
    return Vec3{ .x = x, .y = y, .z = z };
}

pub fn newVec2(x: f32, y: f32) Vec2 {
    return Vec2{ .x = x, .y = y };
}

pub const Vec4 = packed struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,
};

pub fn newVec4(x: f32, y: f32, z: f32, w: f32) Vec4 {
    return Vec4{ .x = x, .y = y, .z = z, .w = w };
}
