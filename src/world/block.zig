const Vec3 = @import("../util.zig").Vec3;
const newVec3 = @import("../util.zig").newVec3;

pub const Block = enum(u8) {
    Air,
    Solid,

    pub fn isSolid(self: Block) bool {
        return self != .Air;
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
        switch (self) {
            .NegY => return newVec3(0, -1, 0),
            .PosY => return newVec3(0, 1, 0),
            .NegX => return newVec3(-1, 0, 0),
            .PosX => return newVec3(1, 0, 0),
            .NegZ => return newVec3(0, 0, -1),
            .PosZ => return newVec3(0, 0, 1),
        }
    }
};
