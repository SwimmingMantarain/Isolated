const std = @import("std");
const noize = @import("noize");
const gl = @cImport(@cInclude("glad/glad.h"));
const glfw = @import("glfw");

const Block = @import("./block.zig").Block;
const Face = @import("./block.zig").Face;
const ChunkMesh = @import("./mesh.zig").ChunkMesh;
const GreedyQuad = @import("./mesh.zig").GreedyQuad;
const Vertex = @import("./mesh.zig").Vertex;
const OpenGLContext = @import("../renderer/opengl.zig").OpenGLContext;
const iVec3 = @import("../util.zig").iVec3;

const newVec3 = @import("../util.zig").newVec3;
const newVec2 = @import("../util.zig").newVec2;
const greedyMesh = @import("./mesh.zig").greedyMesh;

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
        self.mutex.lock();
        self.fmesh.destroy(alloc);
        self.bmesh.destroy(alloc);
        self.mutex.unlock();
        alloc.destroy(self);
    }

    pub fn getBlock(self: *Chunk, x: usize, y: usize, z: usize) Block {
        return self.blocks[y + (x * 32) + (z * 32 * 32)];
    }

    pub fn getNeighbour(self: *Chunk, face: Face, x: usize, y: usize) Block {
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
        neighbours: []?*Chunk,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state == .Destroying) return;

        self.state = .Meshing;

        self.bmesh.vertices.clearRetainingCapacity();
        self.bmesh.indices.clearRetainingCapacity();

        const start = glfw.getTime();

        // Build binary representation
        var axis_cols: [3 * 32 * 32]u32 = undefined;
        @memset(&axis_cols, 0);

        for (0..32) |z| {
            for (0..32) |y| {
                for (0..32) |x| {
                    const block = self.blocks[y + (x * 32) + (z * 32 * 32)];
                    if (!block.isSolid()) continue;

                    axis_cols[(0 * 32 * 32) + (z * 32) + (x)] |= @as(u32, @intCast(1)) << @intCast(y);
                    axis_cols[(1 * 32 * 32) + (y * 32) + (z)] |= @as(u32, @intCast(1)) << @intCast(x);
                    axis_cols[(2 * 32 * 32) + (y * 32) + (x)] |= @as(u32, @intCast(1)) << @intCast(z);
                }
            }
        }

        // Face cull internal blocks
        var face_col_masks: [6 * 32 * 32]u32 = undefined;
        @memset(&face_col_masks, 0);

        for (0..3) |axis| {
            const base_face = 2 * 32 * 32 * axis;
            for (0..32) |z| {
                for (0..32) |x| {
                    const col = axis_cols[(axis * 32 * 32) + (z * 32) + (x)];

                    face_col_masks[(base_face) + (z * 32) + (x)] = col & ~(col << 1); // Descending axis
                    face_col_masks[(base_face + 32 * 32) + (z * 32) + (x)] = col & ~(col >> 1); // Ascending axis
                }
            }
        }

        // Face cull borders
        for (0..6) |face_idx| {
            const face: Face = @enumFromInt(face_idx);

            if (neighbours[face_idx]) |neighbour| {
                const opposites = [_]Face{
                    .PosY, .NegY,
                    .PosX, .NegX,
                    .PosZ, .NegZ,
                };
                const opposite_face = opposites[face_idx];

                neighbour.mutex.lock();
                const neighbour_border = neighbour.getBorder(opposite_face);
                neighbour.mutex.unlock();

                const face_base = face_idx * 32 * 32;
                const axis = face_idx / 2; // 0 = Y, 1 = X, 2 = Z

                var neighbour_cols: [32 * 32]u32 = undefined;
                @memset(&neighbour_cols, 0);

                if (axis == 0) { // Y
                    for (0..32) |z| {
                        for (0..32) |x| {
                            const border_idx = z * 32 + x;
                            // Check if ANY solid block exists
                            if (neighbour_border[border_idx] != .Air) {
                                const bit_pos: u5 = if (face == .PosY) 31 else 0;
                                neighbour_cols[z * 32 + x] |= (@as(u32, 1) << bit_pos);
                            }
                        }
                    }
                } else if (axis == 1) { // X
                    for (0..32) |y| {
                        for (0..32) |z| {
                            const border_idx = y * 32 + z;
                            if (neighbour_border[border_idx] != .Air) {
                                const bit_pos: u5 = if (face == .PosX) 31 else 0;
                                neighbour_cols[y * 32 + z] |= (@as(u32, 1) << bit_pos);
                            }
                        }
                    }
                } else { // Z
                    for (0..32) |y| {
                        for (0..32) |x| {
                            const border_idx = y * 32 + x;
                            if (neighbour_border[border_idx] != .Air) {
                                const bit_pos: u5 = if (face == .PosZ) 31 else 0;
                                neighbour_cols[y * 32 + x] |= (@as(u32, 1) << bit_pos);
                            }
                        }
                    }
                }

                for (0..32 * 32) |i| {
                    face_col_masks[face_base + i] &= ~neighbour_cols[i];
                }
            }
        }

        // iterate over each block type
        const kinds = std.enums.values(Block);
        for (kinds) |kind| {
            if (kind == .Air) continue;

            // Build 2d planes
            var planes: [6 * 32 * 32]u32 = undefined;
            @memset(&planes, 0);

            for (0..6) |face| {
                const axis = @divTrunc(face, 2);
                for (0..32) |x| {
                    for (0..32) |z| {
                        var col = face_col_masks[(face * 32 * 32) + (z * 32) + (x)];

                        while (col != 0) {
                            const y: u32 = @ctz(col);
                            col &= col - 1;

                            // Correctly map loop variables to coordinates based on axis
                            const bx = switch (axis) {
                                0 => x,
                                1 => y, // Axis 1 (X) uses 'y' (bit) as X coordinate
                                2 => x,
                                else => unreachable,
                            };
                            const by = switch (axis) {
                                0 => y, // Axis 0 (Y) uses 'y' (bit) as Y coordinate
                                1 => z,
                                2 => z,
                                else => unreachable,
                            };
                            const bz = switch (axis) {
                                0 => z,
                                1 => x,
                                2 => y, // Axis 2 (Z) uses 'y' (bit) as Z coordinate
                                else => unreachable,
                            };

                            const block = self.blocks[by + (bx * 32) + (bz * 32 * 32)];

                            switch (axis) {
                                0 => if (block == kind) {
                                    planes[(face * 32 * 32) + (y * 32) + x] |= @as(u32, 1) << @as(u5, @intCast(z));
                                },
                                1 => if (block == kind) {
                                    planes[(face * 32 * 32) + (y * 32) + z] |= @as(u32, 1) << @as(u5, @intCast(x));
                                },
                                2 => if (block == kind) {
                                    planes[(face * 32 * 32) + (y * 32) + x] |= @as(u32, 1) << @as(u5, @intCast(z));
                                },
                                else => unreachable,
                            }
                        }
                    }
                }
            }

            var quads = try std.ArrayList(GreedyQuad).initCapacity(alloc, 512);
            defer quads.deinit(alloc);

            // Greedy mesh
            for (0..6) |face| {
                for (0..32) |layer| {
                    quads.clearRetainingCapacity();

                    const layer_ptr = @as(*[32]u32, @ptrCast(&planes[(face * 32 * 32) + (layer * 32)]));
                    try greedyMesh(layer_ptr, &quads);

                    try self.bmesh.vertices.ensureUnusedCapacity(alloc, quads.items.len * 4);
                    for (quads.items) |quad| {
                        quad.appendVertices(&self.bmesh.vertices, @enumFromInt(face), layer, kind);
                    }
                }
            }
        }

        const elapsed = glfw.getTime() - start;
        std.debug.print("Chunk vertices gened in: {d}\n", .{elapsed * 1000});

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

    pub fn uploadMesh(self: *Chunk) void {
        if (self.state == .Destroying) return;

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

        if (self.state == .Destroying) return;

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

    pub fn getBorder(self: *Chunk, face: Face) []Block {
        const face_idx: usize = @intFromEnum(face);
        const face_base: usize = face_idx * 32 * 32;
        return self.border_blocks[face_base .. face_base + 32 * 32];
    }
};
