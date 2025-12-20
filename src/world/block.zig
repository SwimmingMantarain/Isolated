const Vec3 = @import("../util.zig").Vec3;
const Vec2 = @import("../util.zig").Vec2;
const newVec3 = @import("../util.zig").newVec3;
const newVec2 = @import("../util.zig").newVec2;

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

    pub fn uv(self: Block, face: Face) Vec2 {
        return switch (self) {
            .Air => unreachable, // no texture for air
            .Grass => {
                return switch (face) {
                    // vec2: col, row
                    .PosY => newVec2(0, 0),
                    .NegY => newVec2(1, 0),
                    else => newVec2(2, 0),
                };
            },
            .Dirt => newVec2(1, 0),
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
