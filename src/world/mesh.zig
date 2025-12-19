const std = @import("std");
const gl = @cImport(@cInclude("glad/glad.h"));

const Vec3 = @import("../util.zig").Vec3;
const Vec2 = @import("../util.zig").Vec2;

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
        gl.glDeleteVertexArrays(1, &self.vao);
        gl.glDeleteBuffers(1, &self.vbo);
        gl.glDeleteBuffers(1, &self.ebo);

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
