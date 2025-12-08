const Vec3 = @import("../util.zig").Vec3;
const newVec3 = @import("../util.zig").newVec3;

pub const Block = enum(u8) {
    Air,
    Grass,
    Dirt,

    pub fn isSolid(self: Block) bool {
        return self != .Air;
    }

    pub fn color(self: Block) Vec3 {
        // Shouldn't ever be called as air
        return switch (self) {
            .Grass => newVec3(0.2, 0.4, 0.3),
            .Dirt => newVec3(0.337, 0.224, 0.0),
            else => unreachable,
        };
    }
};

pub const Face = enum(u8) {
    NegY,
    PosY,
    NegX,
    PosX,
    NegZ,
    PosZ,

    pub fn normal(self: Face) Vec3 {
        return switch (self) {
            .NegY => newVec3(0, -1, 0),
            .PosY => newVec3(0, 1, 0),
            .NegX => newVec3(-1, 0, 0),
            .PosX => newVec3(1, 0, 0),
            .NegZ => newVec3(0, 0, -1),
            .PosZ => newVec3(0, 0, 1),
        };
    }
};
