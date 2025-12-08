const std = @import("std");
const gl = @cImport(@cInclude("glad/glad.h"));

const Vec3 = @import("../util.zig").Vec3;

pub const Vertex = packed struct {
    pos: Vec3,
    norm: Vec3,
    col: Vec3,
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

        mesh_ptr.vertices = try .initCapacity(alloc, 8192); // Random value, seems good enough
        mesh_ptr.indices = try .initCapacity(alloc, 6 * 8192);
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
        gl.glBufferData(
            gl.GL_ARRAY_BUFFER,
            @intCast(self.vertices.items.len * @sizeOf(Vertex)),
            self.vertices.items.ptr,
            gl.GL_DYNAMIC_DRAW,
        );

        if (self.ebo == 0) gl.glGenBuffers(1, &self.ebo);
        gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, self.ebo);
        gl.glBufferData(
            gl.GL_ELEMENT_ARRAY_BUFFER,
            @intCast(self.indices.items.len * @sizeOf(u32)),
            self.indices.items.ptr,
            gl.GL_DYNAMIC_DRAW,
        );

        // vertices
        gl.glVertexAttribPointer(0, 3, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(Vertex), null);
        gl.glEnableVertexAttribArray(0);

        // normals
        gl.glVertexAttribPointer(1, 3, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(Vertex), @ptrFromInt(3 * @sizeOf(f32)));
        gl.glEnableVertexAttribArray(1);

        // colors
        gl.glVertexAttribPointer(2, 3, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(Vertex), @ptrFromInt(6 * @sizeOf(f32)));
        gl.glEnableVertexAttribArray(2);
    }
};
