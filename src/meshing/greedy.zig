const std = @import("std");

const Vertex = @import("../world/mesh.zig").Vertex;
const Face = @import("../world/block.zig").Face;
const Block = @import("../world/block.zig").Block;

const newVec3 = @import("../util.zig").newVec3;

pub const GreedyQuad = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,

    pub fn appendVertices(
        self: GreedyQuad,
        vertices: *std.ArrayListUnmanaged(Vertex),
        face: Face,
        axis: u32,
        block: Block,
    ) void {
        const normal = Face.normal(face);
        const color = block.color();

        const fx = @as(f32, @floatFromInt(self.x));
        const fy = @as(f32, @floatFromInt(self.y));
        const fa = @as(f32, @floatFromInt(axis));
        const fw = @as(f32, @floatFromInt(self.w));
        const fh = @as(f32, @floatFromInt(self.h));

        switch (face) {
            .PosY => {
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx, fa + 1.0, fy), .norm = normal, .col = color });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx + fw, fa + 1.0, fy), .norm = normal, .col = color });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx + fw, fa + 1.0, fy + fh), .norm = normal, .col = color });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx, fa + 1.0, fy + fh), .norm = normal, .col = color });
            },
            .NegY => {
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx, fa, fy), .norm = normal, .col = color });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx + fw, fa, fy), .norm = normal, .col = color });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx + fw, fa, fy + fh), .norm = normal, .col = color });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx, fa, fy + fh), .norm = normal, .col = color });
            },
            .PosX => {
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fa + 1.0, fx, fy), .norm = normal, .col = color });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fa + 1.0, fx + fw, fy), .norm = normal, .col = color });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fa + 1.0, fx + fw, fy + fh), .norm = normal, .col = color });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fa + 1.0, fx, fy + fh), .norm = normal, .col = color });
            },
            .NegX => {
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fa, fx, fy), .norm = normal, .col = color });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fa, fx + fw, fy), .norm = normal, .col = color });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fa, fx + fw, fy + fh), .norm = normal, .col = color });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fa, fx, fy + fh), .norm = normal, .col = color });
            },
            .PosZ => {
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx, fy, fa + 1.0), .norm = normal, .col = color });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx + fw, fy, fa + 1.0), .norm = normal, .col = color });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx + fw, fy + fh, fa + 1.0), .norm = normal, .col = color });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx, fy + fh, fa + 1.0), .norm = normal, .col = color });
            },
            .NegZ => {
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx, fy, fa), .norm = normal, .col = color });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx + fw, fy, fa), .norm = normal, .col = color });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx + fw, fy + fh, fa), .norm = normal, .col = color });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx, fy + fh, fa), .norm = normal, .col = color });
            },
        }
    }
};

pub fn greedyMeshBinaryPlane(data: *[32]u32, quads: *std.ArrayList(GreedyQuad), alloc: std.mem.Allocator) !void {
    for (0..32) |row| {
        var y: u32 = 0;
        while (y < 32) {
            // Find first solid
            const trailing = @ctz(data[row] >> @intCast(y));
            y += trailing;
            if (y >= 32) continue;

            // Find height
            const h = @ctz(~(data[row] >> @intCast(y)));

            // Create mask for this height
            const h_as_mask = if (h >= 32) ~@as(u32, 0) else (@as(u32, 1) << @intCast(h)) - 1;
            const mask = h_as_mask << @intCast(y);

            // Grow horizontally
            var w: u32 = 1;
            while (row + w < 32) {
                const next_row_h = (data[row + w] >> @intCast(y)) & h_as_mask;
                if (next_row_h != h_as_mask) break;

                data[row + w] &= ~mask;
                w += 1;
            }

            try quads.append(alloc, GreedyQuad{
                .x = @intCast(row),
                .y = y,
                .w = w,
                .h = h,
            });

            y += h;
        }
    }
}
