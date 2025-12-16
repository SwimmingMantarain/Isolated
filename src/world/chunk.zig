const std = @import("std");
const noize = @import("noize");
const gl = @cImport(@cInclude("glad/glad.h"));

const Block = @import("./block.zig").Block;
const Face = @import("./block.zig").Face;
const ChunkMesh = @import("./mesh.zig").ChunkMesh;
const Vertex = @import("./mesh.zig").Vertex;
const OpenGLContext = @import("../renderer/opengl.zig").OpenGLContext;
const iVec3 = @import("../util.zig").iVec3;

const newVec3 = @import("../util.zig").newVec3;
const newVec2 = @import("../util.zig").newVec2;

pub const ChunkState = enum {
    Idle,
    New,
    ToMesh,
    ToUpload,
    Meshing,
    Uploading,
    Generating,
    Destroying,
};

const FACE_INDICES = [_]u32{ 0, 1, 2, 0, 2, 3 };

pub const Chunk = struct {
    blocks: [32 * 32 * 32]Block,
    border_blocks: [6 * 32 * 32]Block,
    fmesh: *ChunkMesh,
    bmesh: *ChunkMesh,
    pos: iVec3,
    state: ChunkState,
    mutex: std.Thread.Mutex,

    pub fn create(alloc: std.mem.Allocator, pos: iVec3) !*Chunk {
        const chunk_ptr = try alloc.create(Chunk);
        errdefer alloc.destroy(chunk_ptr);

        @memset(&chunk_ptr.blocks, .Air);

        chunk_ptr.fmesh = try ChunkMesh.create(alloc);
        chunk_ptr.bmesh = try ChunkMesh.create(alloc);
        chunk_ptr.pos = pos;
        chunk_ptr.state = .New;
        chunk_ptr.mutex = .{};

        return chunk_ptr;
    }

    pub fn destroy(self: *Chunk, alloc: std.mem.Allocator) void {
        self.fmesh.destroy(alloc);
        self.bmesh.destroy(alloc);
        alloc.destroy(self);
    }

    pub fn getBlock(self: *Chunk, x: u32, y: u32, z: u32) Block {
        return self.blocks[y + (x * 32) + (z * 32 * 32)];
    }

    pub fn getNeighbour(self: *Chunk, face: Face, x: u32, y: u32) Block {
        return self.border_blocks[(@as(u32, @intFromEnum(face)) * 32 * 32) + (32 * y) + x];
    }

    pub fn setBlock(self: *Chunk, x: u32, y: u32, z: u32, kind: Block) void {
        self.blocks[y + (x * 32) + (z * 32 * 32)] = kind;
    }

    pub fn generate(self: *Chunk) void {
        self.mutex.lock();
        for (0..3) |y| {
            for (0..32) |x| {
                for (0..32) |z| {
                    self.setBlock(@intCast(x), @intCast(y), @intCast(z), .Dirt);
                }
            }
        }

        for (0..32) |x| {
            for (0..32) |z| {
                self.setBlock(@intCast(x), 3, @intCast(z), .Grass);
            }
        }

        self.state = .ToMesh;
        self.mutex.unlock();
    }

    pub fn mesh(
        self: *Chunk,
        alloc: std.mem.Allocator,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.state = .Meshing;

        self.bmesh.vertices.clearRetainingCapacity();
        self.bmesh.indices.clearRetainingCapacity();

        for (0..32) |y| {
            for (0..32) |x| {
                for (0..32) |z| {
                    const block = self.getBlock(@intCast(x), @intCast(y), @intCast(z));
                    if (!block.isSolid()) continue;

                    // Handle neighbour chunks
                    if (y == 0 or y == 31 or x == 0 or x == 31 or z == 0 or z == 31) {
                        if (y == 0) { // NegY Face
                            const neighbour_block = self.getNeighbour(.NegY, @intCast(x), @intCast(z));
                            if (!neighbour_block.isSolid()) {
                                try self.appendVertices(x, y, z, .NegY, block, alloc);
                            }
                        } else if (y == 31) { // PosY Face
                            const neighbour_block = self.getNeighbour(.PosY, @intCast(x), @intCast(z));
                            if (!neighbour_block.isSolid()) {
                                try self.appendVertices(x, y, z, .PosY, block, alloc);
                            }
                        }

                        if (x == 0) { // NegX Face
                            const neighbour_block = self.getNeighbour(.NegX, @intCast(z), @intCast(y));
                            if (!neighbour_block.isSolid()) {
                                try self.appendVertices(x, y, z, .NegX, block, alloc);
                            }
                        } else if (x == 31) { // PosX Face
                            const neighbour_block = self.getNeighbour(.PosX, @intCast(z), @intCast(y));
                            if (!neighbour_block.isSolid()) {
                                try self.appendVertices(x, y, z, .PosX, block, alloc);
                            }
                        }

                        if (z == 0) { // NegZ Face
                            const neighbour_block = self.getNeighbour(.NegZ, @intCast(x), @intCast(y));
                            if (!neighbour_block.isSolid()) {
                                try self.appendVertices(x, y, z, .NegZ, block, alloc);
                            }
                        } else if (z == 31) { // PosZ Face
                            const neighbour_block = self.getNeighbour(.PosZ, @intCast(x), @intCast(y));
                            if (!neighbour_block.isSolid()) {
                                try self.appendVertices(x, y, z, .PosZ, block, alloc);
                            }
                        }
                    }

                    // Handle blocks inside chunk
                    if (y > 0 and !self.getBlock(@intCast(x), @intCast(y - 1), @intCast(z)).isSolid()) {
                        try self.appendVertices(x, y, z, .NegY, block, alloc);
                    }
                    if (y < 31 and !self.getBlock(@intCast(x), @intCast(y + 1), @intCast(z)).isSolid()) {
                        try self.appendVertices(x, y, z, .PosY, block, alloc);
                    }
                    if (x > 0 and !self.getBlock(@intCast(x - 1), @intCast(y), @intCast(z)).isSolid()) {
                        try self.appendVertices(x, y, z, .NegX, block, alloc);
                    }
                    if (x < 31 and !self.getBlock(@intCast(x + 1), @intCast(y), @intCast(z)).isSolid()) {
                        try self.appendVertices(x, y, z, .PosX, block, alloc);
                    }
                    if (z > 0 and !self.getBlock(@intCast(x), @intCast(y), @intCast(z - 1)).isSolid()) {
                        try self.appendVertices(x, y, z, .NegZ, block, alloc);
                    }
                    if (z < 31 and !self.getBlock(@intCast(x), @intCast(y), @intCast(z + 1)).isSolid()) {
                        try self.appendVertices(x, y, z, .PosZ, block, alloc);
                    }
                }
            }
        }

        // Generate indices for all vertices
        const vertex_count = self.bmesh.vertices.items.len;
        const quad_count = vertex_count / 4;

        try self.bmesh.indices.ensureTotalCapacity(alloc, quad_count * 6);
        for (0..quad_count) |i| {
            const base: u32 = @intCast(i * 4);
            for (FACE_INDICES) |idx| {
                self.bmesh.indices.appendAssumeCapacity(base + idx);
            }
        }

        self.state = .ToUpload;
    }

    pub fn appendVertices(
        self: *Chunk,
        ux: usize,
        uy: usize,
        uz: usize,
        face: Face,
        kind: Block,
        alloc: std.mem.Allocator,
    ) !void {
        const normal = Face.normal(face);
        const texCoords = kind.uv(face);

        try self.bmesh.vertices.ensureUnusedCapacity(alloc, 4);

        const x: f32 = @floatFromInt(ux);
        const y: f32 = @floatFromInt(uy);
        const z: f32 = @floatFromInt(uz);

        switch (face) {
            .PosY => {
                self.bmesh.vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(x, y + 1.0, z), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(0, 0) });
                self.bmesh.vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(x + 1.0, y + 1.0, z), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(1.0, 0) });
                self.bmesh.vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(x + 1.0, y + 1.0, z + 1.0), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(1.0, 1.0) });
                self.bmesh.vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(x, y + 1.0, z + 1.0), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(0, 1.0) });
            },
            .NegY => {
                self.bmesh.vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(x, y, z), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(0, 0) });
                self.bmesh.vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(x + 1.0, y, z), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(1.0, 0) });
                self.bmesh.vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(x + 1.0, y, z + 1.0), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(1.0, 1.0) });
                self.bmesh.vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(x, y, z + 1.0), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(0, 1.0) });
            },
            .PosX => {
                self.bmesh.vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(x + 1.0, y, z), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(1.0, 1.0) });
                self.bmesh.vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(x + 1.0, y + 1.0, z), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(1.0, 0) });
                self.bmesh.vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(x + 1.0, y + 1.0, z + 1.0), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(0, 0) });
                self.bmesh.vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(x + 1.0, y, z + 1.0), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(0, 1.0) });
            },
            .NegX => {
                self.bmesh.vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(x, y, z), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(0, 1.0) });
                self.bmesh.vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(x, y + 1.0, z), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(0, 0) });
                self.bmesh.vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(x, y + 1.0, z + 1.0), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(1.0, 0) });
                self.bmesh.vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(x, y, z + 1.0), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(1.0, 1.0) });
            },
            .PosZ => {
                self.bmesh.vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(x, y, z + 1.0), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(1.0, 1.0) });
                self.bmesh.vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(x + 1.0, y, z + 1.0), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(0, 1.0) });
                self.bmesh.vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(x + 1.0, y + 1.0, z + 1.0), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(0, 0) });
                self.bmesh.vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(x, y + 1.0, z + 1.0), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(1.0, 0) });
            },
            .NegZ => {
                self.bmesh.vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(x, y, z), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(0, 1) });
                self.bmesh.vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(x + 1.0, y, z), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(1, 1) });
                self.bmesh.vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(x + 1.0, y + 1.0, z), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(1, 0) });
                self.bmesh.vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(x, y + 1.0, z), .norm = normal, .tex_id = texCoords, .tex_uv = newVec2(0, 0) });
            },
        }
    }

    pub fn uploadMesh(self: *Chunk) void {
        self.state = .Uploading;

        self.bmesh.upload();

        const tmesh = self.fmesh;
        self.fmesh = self.bmesh;
        self.bmesh = tmesh;

        self.state = .Idle;
    }

    pub fn borders(self: *Chunk, neighbours: []?*Chunk) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        @memset(&self.border_blocks, .Air);

        for (0..6) |face_idx| {
            const face: Face = @enumFromInt(face_idx);
            const face_base = face_idx * 32 * 32;
            const neighbour = neighbours[face_idx];

            switch (face) {
                .PosY => {
                    if (neighbour != null) {
                        for (0..32) |z| {
                            for (0..32) |x| {
                                const block_idx = 0 + (x * 32) + (32 * 32 * z);
                                const border_idx = face_base + (z * 32) + x;
                                self.border_blocks[border_idx] = neighbour.?.blocks[block_idx];
                            }
                        }
                    }
                },
                .NegY => {
                    if (neighbour != null) {
                        for (0..32) |z| {
                            for (0..32) |x| {
                                const block_idx = 31 + (x * 32) + (32 * 32 * z);
                                const border_idx = face_base + (z * 32) + x;
                                self.border_blocks[border_idx] = neighbour.?.blocks[block_idx];
                            }
                        }
                    }
                },
                .PosX => {
                    if (neighbour != null) {
                        for (0..32) |y| {
                            for (0..32) |z| {
                                const block_idx = y + (0 * 32) + (32 * 32 * z);
                                const border_idx = face_base + (y * 32) + z;
                                self.border_blocks[border_idx] = neighbour.?.blocks[block_idx];
                            }
                        }
                    }
                },
                .NegX => {
                    if (neighbour != null) {
                        for (0..32) |y| {
                            for (0..32) |z| {
                                const block_idx = y + (31 * 32) + (32 * 32 * z);
                                const border_idx = face_base + (y * 32) + z;
                                self.border_blocks[border_idx] = neighbour.?.blocks[block_idx];
                            }
                        }
                    }
                },
                .PosZ => {
                    if (neighbour != null) {
                        for (0..32) |y| {
                            for (0..32) |x| {
                                const block_idx = y + (x * 32) + (0 * 32 * 32);
                                const border_idx = face_base + (y * 32) + x;
                                self.border_blocks[border_idx] = neighbour.?.blocks[block_idx];
                            }
                        }
                    }
                },
                .NegZ => {
                    if (neighbour != null) {
                        for (0..32) |y| {
                            for (0..32) |x| {
                                const block_idx = y + (x * 32) + (31 * 32 * 32);
                                const border_idx = face_base + (y * 32) + x;
                                self.border_blocks[border_idx] = neighbour.?.blocks[block_idx];
                            }
                        }
                    }
                },
            }
        }
    }
};
