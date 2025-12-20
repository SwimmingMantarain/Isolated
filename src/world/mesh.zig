const std = @import("std");
const gl = @cImport(@cInclude("glad/glad.h"));

const Vec3 = @import("../util.zig").Vec3;
const Vec2 = @import("../util.zig").Vec2;
const Face = @import("./block.zig").Face;
const Block = @import("./block.zig").Block;

const newVec3 = @import("../util.zig").newVec3;
const newVec2 = @import("../util.zig").newVec2;

pub const Vertex = packed struct {
    pos: Vec3,
    norm: Vec3,
    tex_id: Vec2, // xy: tile id
    tex_uv: Vec2, // zw: local uv
};

pub const ChunkMesh = struct {
    vertices: std.ArrayListUnmanaged(Vertex),
    indices: std.ArrayListUnmanaged(u32),
    vao: c_uint,
    vbo: c_uint,
    ebo: c_uint,

    pub fn create(alloc: std.mem.Allocator) !*ChunkMesh {
        const mesh_ptr = try alloc.create(ChunkMesh); // TODO: add logging to console
        errdefer alloc.destroy(mesh_ptr);

        mesh_ptr.vertices = try .initCapacity(alloc, 2 * 8192); // Random value, seems good enough
        mesh_ptr.indices = try .initCapacity(alloc, 12 * 8192);
        mesh_ptr.vao = 0;
        mesh_ptr.vbo = 0;
        mesh_ptr.ebo = 0;

        return mesh_ptr;
    }

    pub fn destroy(self: *ChunkMesh, alloc: std.mem.Allocator) void {
        // Only delete OpenGL resources if they were created
        if (self.vao != 0) {
            gl.glDeleteVertexArrays(1, &self.vao);
        }
        if (self.vbo != 0) {
            gl.glDeleteBuffers(1, &self.vbo);
        }
        if (self.ebo != 0) {
            gl.glDeleteBuffers(1, &self.ebo);
        }

        self.vertices.deinit(alloc);
        self.indices.deinit(alloc);
        alloc.destroy(self);
    }

    pub fn upload(self: *ChunkMesh) void {
        if (self.vao == 0) gl.glGenVertexArrays(1, &self.vao);
        gl.glBindVertexArray(self.vao);

        if (self.vbo == 0) gl.glGenBuffers(1, &self.vbo);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, self.vbo);

        const vbo_size: c_long = @intCast(self.vertices.items.len * @sizeOf(Vertex));
        gl.glBufferData(gl.GL_ARRAY_BUFFER, vbo_size, null, gl.GL_DYNAMIC_DRAW);
        gl.glBufferData(gl.GL_ARRAY_BUFFER, vbo_size, self.vertices.items.ptr, gl.GL_DYNAMIC_DRAW);

        if (self.ebo == 0) gl.glGenBuffers(1, &self.ebo);
        gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, self.ebo);

        const ebo_size: c_long = @intCast(self.indices.items.len * @sizeOf(u32));
        gl.glBufferData(gl.GL_ELEMENT_ARRAY_BUFFER, ebo_size, null, gl.GL_DYNAMIC_DRAW);
        gl.glBufferData(gl.GL_ELEMENT_ARRAY_BUFFER, ebo_size, self.indices.items.ptr, gl.GL_DYNAMIC_DRAW);

        // vertices
        gl.glVertexAttribPointer(0, 3, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(Vertex), null);
        gl.glEnableVertexAttribArray(0);

        // normals
        gl.glVertexAttribPointer(1, 3, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(Vertex), @ptrFromInt(3 * @sizeOf(f32)));
        gl.glEnableVertexAttribArray(1);

        // texture coords: https://community.khronos.org/t/repeat-tile-from-texture-atlas/104500
        gl.glVertexAttribPointer(2, 4, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(Vertex), @ptrFromInt(6 * @sizeOf(f32)));
        gl.glEnableVertexAttribArray(2);
    }
};

pub const GreedyQuad = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,

    pub fn appendVertices(
        self: GreedyQuad,
        vertices: *std.ArrayListUnmanaged(Vertex),
        face: Face,
        axis: usize,
        block: Block,
    ) void {
        const normal = Face.normal(face);
        const texCoords = block.uv(face);

        const fx = @as(f32, @floatFromInt(self.x));
        const fy = @as(f32, @floatFromInt(self.y));
        const fa = @as(f32, @floatFromInt(axis));
        const fw = @as(f32, @floatFromInt(self.w));
        const fh = @as(f32, @floatFromInt(self.h));

        switch (face) {
            .PosY => {
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx, fa + 1.0, fy), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(0, 0) });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx + fw, fa + 1.0, fy), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(fw, 0) });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx + fw, fa + 1.0, fy + fh), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(fw, fh) });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx, fa + 1.0, fy + fh), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(0, fh) });
            },
            .NegY => {
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx, fa, fy), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(0, 0) });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx + fw, fa, fy), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(fw, 0) });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx + fw, fa, fy + fh), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(fw, fh) });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx, fa, fy + fh), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(0, fh) });
            },
            .PosX => {
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fa + 1.0, fx, fy), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(fh, fw) });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fa + 1.0, fx + fw, fy), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(fh, 0) });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fa + 1.0, fx + fw, fy + fh), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(0, 0) });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fa + 1.0, fx, fy + fh), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(0, fw) });
            },
            .NegX => {
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fa, fx, fy), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(0, fw) });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fa, fx + fw, fy), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(0, 0) });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fa, fx + fw, fy + fh), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(fh, 0) });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fa, fx, fy + fh), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(fh, fw) });
            },
            .PosZ => {
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx, fy, fa + 1.0), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(0, fh) });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx + fw, fy, fa + 1.0), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(fw, fh) });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx + fw, fy + fh, fa + 1.0), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(fw, 0) });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx, fy + fh, fa + 1.0), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(0, 0) });
            },
            .NegZ => {
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx, fy, fa), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(fw, fh) });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx + fw, fy, fa), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(0, fh) });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx + fw, fy + fh, fa), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(0, 0) });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx, fy + fh, fa), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(fw, 0) });
            },
        }
    }
};

pub fn greedyMesh(data: *[32]u32, quads: *std.ArrayList(GreedyQuad)) !void {
    for (0..32) |row| {
        var y: u32 = 0;
        while (y < 32) {
            const trailing = @ctz(data[row] >> @intCast(y));
            y += trailing;
            if (y >= 32) continue;

            const h = @ctz(~(data[row] >> @intCast(y)));

            const h_as_mask = if (h >= 32) ~@as(u32, 0) else (@as(u32, 1) << @intCast(h)) - 1;
            const mask = h_as_mask << @intCast(y);

            var w: u32 = 1;
            while (row + w < 32) {
                const next_row_h = (data[row + w] >> @intCast(y)) & h_as_mask;
                if (next_row_h != h_as_mask) break;

                data[row + w] &= ~mask;
                w += 1;
            }

            quads.appendAssumeCapacity(GreedyQuad{ .x = @intCast(row), .y = y, .w = w, .h = h });
            y += h;
        }
    }
}
