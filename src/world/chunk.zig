const std = @import("std");

const Block = @import("./block.zig").Block;
const Face = @import("./block.zig").Face;
const ChunkMesh = @import("./mesh.zig").ChunkMesh;
const GreedyQuad = @import("../meshing/greedy.zig").GreedyQuad;
const OpenCLContext = @import("../opencl/opencl.zig").OpenCLContext;
const iVec3 = @import("../util.zig").iVec3;
const Gen = @import("noize").Gen;

const greedyMeshBinaryPlane = @import("../meshing/greedy.zig").greedyMeshBinaryPlane;
const genChunk = @import("../worldgen/gen.zig").genChunk;

const cl = @import("cl").cl;

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

    pub fn getBlock(self: *Chunk, x: u8, y: u8, z: u8) Block {
        return self.blocks[y + (x * 32) + (z * 32 * 32)];
    }

    pub fn setBlock(self: *Chunk, x: u8, y: u8, z: u8, kind: Block) void {
        self.blocks[y + (x * 32) + (z * 32 * 32)] = kind;
    }

    pub fn generate(self: *Chunk, gen: *Gen) void {
        self.mutex.lock();
        genChunk(self, gen);
        self.state = .ToMesh;
        self.mutex.unlock();
    }

    pub fn buildMesh(
        self: *Chunk,
        alloc: std.mem.Allocator,
        neighbours: []?*Chunk,
        cl_context: *OpenCLContext,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.state = .Meshing;

        self.bmesh.vertices.clearRetainingCapacity();
        self.bmesh.indices.clearRetainingCapacity();

        try self.bmesh.vertices.ensureTotalCapacity(alloc, 8192);
        try self.bmesh.indices.ensureTotalCapacity(alloc, 8192 * 6);

        const blocks_mem = try cl_context.createMem(cl.CL_MEM_READ_ONLY, @sizeOf(u8) * 32 * 32 * 32);
        defer _ = cl.clReleaseMemObject(blocks_mem);
        try cl_context.writeMem(blocks_mem, @sizeOf(u8) * 32 * 32 * 32, &self.blocks);

        // for each block type :)
        const types = std.enums.values(Block);
        for (types) |kind| {
            if (kind == .Air) continue;

            const axis_cols_mem = try cl_context.createMem(cl.CL_MEM_READ_WRITE, 3 * 32 * 32 * @sizeOf(u32));
            defer _ = cl.clReleaseMemObject(axis_cols_mem);

            const col_face_masks_mem = try cl_context.createMem(cl.CL_MEM_READ_WRITE, 6 * 32 * 32 * @sizeOf(u32));
            defer _ = cl.clReleaseMemObject(col_face_masks_mem);

            const out_planes_mem = try cl_context.createMem(cl.CL_MEM_WRITE_ONLY, 6 * 32 * 32 * @sizeOf(u32));
            defer _ = cl.clReleaseMemObject(out_planes_mem);

            var axis_cols: [3 * 32 * 32]u32 = undefined;
            @memset(&axis_cols, 0);

            // Set kernel arguments
            try cl_context.setKernelArg(cl_context.axis_kernel, 0, @sizeOf(cl.cl_mem), @ptrCast(&blocks_mem));
            try cl_context.setKernelArg(cl_context.axis_kernel, 1, @sizeOf(cl.cl_mem), @ptrCast(&axis_cols_mem));
            try cl_context.setKernelArg(cl_context.axis_kernel, 2, @sizeOf(Block), @ptrCast(&kind));

            const axis_work_size = [3]usize{ 32, 32, 32 };
            try cl_context.runKernel(cl_context.axis_kernel, axis_work_size[0..]);
            try cl_context.readMem(axis_cols_mem, @sizeOf(u32) * 3 * 32 * 32, &axis_cols);

            var col_face_masks: [6 * 32 * 32]u32 = undefined;
            @memset(&col_face_masks, 0);

            // Generate face masks by comparing adjacent voxels
            try cl_context.writeMem(axis_cols_mem, 3 * 32 * 32 * @sizeOf(u32), &axis_cols);

            try cl_context.setKernelArg(cl_context.cull_kernel, 0, @sizeOf(cl.cl_mem), @ptrCast(&axis_cols_mem));
            try cl_context.setKernelArg(cl_context.cull_kernel, 1, @sizeOf(cl.cl_mem), @ptrCast(&col_face_masks_mem));

            const cull_work_size = [3]usize{ 3, 32, 32 };
            try cl_context.runKernel(cl_context.cull_kernel, &cull_work_size);
            try cl_context.readMem(col_face_masks_mem, @sizeOf(u32) * 6 * 32 * 32, &col_face_masks);

            // Border control
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
                    const neighbour_border = neighbour.getBorderFace(opposite_face);
                    neighbour.mutex.unlock();

                    const face_base = face_idx * 32 * 32;
                    const axis = face_idx / 2; // 0 = Y, 1 = X, 2 = Z

                    var neighbour_cols: [32 * 32]u32 = undefined;
                    @memset(&neighbour_cols, 0);

                    if (axis == 0) { // Y
                        for (0..32) |z| {
                            for (0..32) |x| {
                                const border_idx = z * 32 + x;
                                if (neighbour_border[border_idx] == kind) {
                                    const bit_pos: u5 = if (face == .PosY) 31 else 0;
                                    neighbour_cols[z * 32 + x] |= (@as(u32, 1) << bit_pos);
                                }
                            }
                        }
                    } else if (axis == 1) { // X
                        for (0..32) |y| {
                            for (0..32) |z| {
                                const border_idx = y * 32 + z;
                                if (neighbour_border[border_idx] == kind) {
                                    const bit_pos: u5 = if (face == .PosX) 31 else 0;
                                    neighbour_cols[y * 32 + z] |= (@as(u32, 1) << bit_pos);
                                }
                            }
                        }
                    } else { // Z
                        for (0..32) |y| {
                            for (0..32) |x| {
                                const border_idx = y * 32 + x;
                                if (neighbour_border[border_idx] == kind) {
                                    const bit_pos: u5 = if (face == .PosZ) 31 else 0;
                                    neighbour_cols[y * 32 + x] |= (@as(u32, 1) << bit_pos);
                                }
                            }
                        }
                    }

                    for (0..32 * 32) |i| {
                        col_face_masks[face_base + i] &= ~neighbour_cols[i];
                    }
                }
            }

            // Create planes for greedy meshing
            var planes: [6 * 32 * 32]u32 = undefined;
            @memset(&planes, 0);

            try cl_context.writeMem(col_face_masks_mem, 6 * 32 * 32 * @sizeOf(u32), &col_face_masks);

            try cl_context.setKernelArg(cl_context.greedy_kernel, 0, @sizeOf(cl.cl_mem), @ptrCast(&col_face_masks_mem));
            try cl_context.setKernelArg(cl_context.greedy_kernel, 1, @sizeOf(cl.cl_mem), @ptrCast(&out_planes_mem));

            const global_size_greedy = [1]usize{6};
            try cl_context.runKernel(cl_context.greedy_kernel, &global_size_greedy);
            try cl_context.readMem(out_planes_mem, @sizeOf(u32) * 6 * 32 * 32, &planes);

            // Greedy mesh each face
            const faces = [_]Face{ .NegY, .PosY, .NegX, .PosX, .NegZ, .PosZ };

            var quads = try std.ArrayList(GreedyQuad).initCapacity(alloc, 2048);
            defer quads.deinit(alloc);

            for (0..6) |face_idx| {
                const face = faces[face_idx];
                const face_base = face_idx * 32 * 32;

                for (0..32) |layer| {
                    quads.clearRetainingCapacity();

                    const layer_ptr = @as(*[32]u32, @ptrCast(&planes[face_base + (layer * 32)]));
                    try greedyMeshBinaryPlane(layer_ptr, &quads, alloc);

                    for (quads.items) |quad| {
                        try self.bmesh.vertices.ensureUnusedCapacity(alloc, 4);
                        quad.appendVertices(&self.bmesh.vertices, face, @intCast(layer), kind);
                    }
                }
            }

            // Generate indices
            const vertex_count = self.bmesh.vertices.items.len;
            const quad_count = vertex_count / 4;

            try self.bmesh.indices.ensureTotalCapacity(alloc, quad_count * 6);
            for (0..quad_count) |i| {
                const base: u32 = @intCast(i * 4);
                for (FACE_INDICES) |idx| {
                    self.bmesh.indices.appendAssumeCapacity(base + idx);
                }
            }
        }

        alloc.free(neighbours);
        self.state = .ToUpload;
    }

    pub fn uploadMesh(self: *Chunk) void {
        self.state = .Uploading;

        self.bmesh.upload();

        const tmesh = self.fmesh;
        self.fmesh = self.bmesh;
        self.bmesh = tmesh;

        self.state = .Idle;
    }

    pub fn updateBorders(self: *Chunk) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        @memset(&self.border_blocks, .Air);

        for (0..6) |face_idx| {
            const face: Face = @enumFromInt(face_idx);
            const face_base = face_idx * 32 * 32;

            switch (face) {
                .PosY => {
                    for (0..32) |z| {
                        for (0..32) |x| {
                            const block_idx = 31 + (x * 32) + (32 * 32 * z);
                            const border_idx = face_base + (z * 32) + x;
                            self.border_blocks[border_idx] = self.blocks[block_idx];
                        }
                    }
                },
                .NegY => {
                    for (0..32) |z| {
                        for (0..32) |x| {
                            const block_idx = 0 + (x * 32) + (32 * 32 * z);
                            const border_idx = face_base + (z * 32) + x;
                            self.border_blocks[border_idx] = self.blocks[block_idx];
                        }
                    }
                },
                .PosX => {
                    for (0..32) |y| {
                        for (0..32) |z| {
                            const block_idx = y + (31 * 32) + (32 * 32 * z);
                            const border_idx = face_base + (y * 32) + z;
                            self.border_blocks[border_idx] = self.blocks[block_idx];
                        }
                    }
                },
                .NegX => {
                    for (0..32) |y| {
                        for (0..32) |z| {
                            const block_idx = y + (0 * 32) + (32 * 32 * z);
                            const border_idx = face_base + (y * 32) + z;
                            self.border_blocks[border_idx] = self.blocks[block_idx];
                        }
                    }
                },
                .PosZ => {
                    for (0..32) |y| {
                        for (0..32) |x| {
                            const block_idx = y + (x * 32) + (31 * 32 * 32);
                            const border_idx = face_base + (y * 32) + x;
                            self.border_blocks[border_idx] = self.blocks[block_idx];
                        }
                    }
                },
                .NegZ => {
                    for (0..32) |y| {
                        for (0..32) |x| {
                            const block_idx = y + (x * 32) + (0 * 32 * 32);
                            const border_idx = face_base + (y * 32) + x;
                            self.border_blocks[border_idx] = self.blocks[block_idx];
                        }
                    }
                },
            }
        }
    }

    pub fn getBorderFace(self: *Chunk, face: Face) []Block {
        const face_idx: usize = @intFromEnum(face);
        const face_base: usize = face_idx * 32 * 32;
        return self.border_blocks[face_base .. face_base + 32 * 32];
    }
};
