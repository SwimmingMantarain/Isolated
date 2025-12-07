const std = @import("std");

pub const Vec3 = packed struct {
    x: f32,
    y: f32,
    z: f32,
};

pub const iVec3 = packed struct {
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
