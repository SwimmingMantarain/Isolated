const std = @import("std");
const glfw = @import("glfw");
const noize = @import("noize");

const Vec3 = @import("../util.zig").Vec3;
const newVec3 = @import("../util.zig").newVec3;

const genChunk = @import("./gen.zig").genChunk;
const World = @import("./world.zig").World;

const gl = @cImport({
    @cInclude("glad/glad.h");
});

const cl = @import("cl").cl;

pub const Block = enum {
    Air,
    Solid,
};

pub const Face = enum { NegY, PosY, NegX, PosX, NegZ, PosZ };

pub const ChunkCoord = struct {
    x: i32,
    y: i32,
    z: i32,

    pub fn hash(self: *ChunkCoord) u64 {
        return std.hash.Wyhash.hash(0, @as([*]const u8, @ptrCast(self))[0..@sizeOf(ChunkCoord)]);
    }
};

const FACE_NORMALS = [_]Vec3{
    newVec3(0, -1, 0), // NegY (bottom)
    newVec3(0, 1, 0), // PosY (top)
    newVec3(-1, 0, 0), // NegX (left)
    newVec3(1, 0, 0), // PosX (right)
    newVec3(0, 0, -1), // NegZ (back)
    newVec3(0, 0, 1), // PosZ (front)
};

const FACE_INDICES = [_]u32{ 0, 1, 2, 0, 2, 3 };

const BIT_MASKS: [32]u32 = blk: {
    var arr: [32]u32 = undefined;
    for (0..32) |i| {
        arr[i] = @as(u32, @intCast(1)) << i;
    }
    break :blk arr;
};

const Vertex = packed struct {
    pos: Vec3,
    norm: Vec3,
};

pub const ChunkMesh = struct {
    vertices: std.ArrayListUnmanaged(Vertex),
    indices: std.ArrayListUnmanaged(u32),
    vao_handle: c_uint,
    vbo_handle: c_uint,
    ebo_handle: c_uint,

    pub fn create(alloc: std.mem.Allocator) !*ChunkMesh {
        const mesh_ptr = alloc.create(ChunkMesh) catch |err| {
            std.log.err("Failed to allocate memory for new chunk mesh", .{});
            return err;
        };

        mesh_ptr.vertices = try .initCapacity(alloc, 8192);
        mesh_ptr.indices = try .initCapacity(alloc, 8192 * 6);
        mesh_ptr.vao_handle = 0;
        mesh_ptr.vbo_handle = 0;
        mesh_ptr.ebo_handle = 0;

        return mesh_ptr;
    }

    pub fn destroy(self: *ChunkMesh, alloc: std.mem.Allocator) void {
        gl.glDeleteVertexArrays(1, &self.vao_handle);
        gl.glDeleteBuffers(1, &self.vbo_handle);
        gl.glDeleteBuffers(1, &self.ebo_handle);

        self.vertices.deinit(alloc);
        self.indices.deinit(alloc);
        alloc.destroy(self);
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
        axis: u32,
    ) void {
        const face_index = @intFromEnum(face);
        const normal = FACE_NORMALS[face_index];

        const fx = @as(f32, @floatFromInt(self.x));
        const fy = @as(f32, @floatFromInt(self.y));
        const fa = @as(f32, @floatFromInt(axis));
        const fw = @as(f32, @floatFromInt(self.w));
        const fh = @as(f32, @floatFromInt(self.h));

        switch (face) {
            .PosY => {
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx, fa + 1.0, fy), .norm = normal });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx + fw, fa + 1.0, fy), .norm = normal });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx + fw, fa + 1.0, fy + fh), .norm = normal });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx, fa + 1.0, fy + fh), .norm = normal });
            },
            .NegY => {
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx, fa, fy), .norm = normal });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx + fw, fa, fy), .norm = normal });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx + fw, fa, fy + fh), .norm = normal });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx, fa, fy + fh), .norm = normal });
            },
            .PosX => {
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fa + 1.0, fx, fy), .norm = normal });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fa + 1.0, fx + fw, fy), .norm = normal });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fa + 1.0, fx + fw, fy + fh), .norm = normal });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fa + 1.0, fx, fy + fh), .norm = normal });
            },
            .NegX => {
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fa, fx, fy), .norm = normal });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fa, fx + fw, fy), .norm = normal });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fa, fx + fw, fy + fh), .norm = normal });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fa, fx, fy + fh), .norm = normal });
            },
            .PosZ => {
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx, fy, fa + 1.0), .norm = normal });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx + fw, fy, fa + 1.0), .norm = normal });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx + fw, fy + fh, fa + 1.0), .norm = normal });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx, fy + fh, fa + 1.0), .norm = normal });
            },
            .NegZ => {
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx, fy, fa), .norm = normal });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx + fw, fy, fa), .norm = normal });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx + fw, fy + fh, fa), .norm = normal });
                vertices.appendAssumeCapacity(Vertex{ .pos = newVec3(fx, fy + fh, fa), .norm = normal });
            },
        }
    }
};

pub const Chunk = struct {
    blocks: [32 * 32 * 32]Block,
    border_data: [6 * 32 * 32]Block,
    front_mesh: *ChunkMesh,
    back_mesh: *ChunkMesh,
    pos: ChunkCoord,
    state: ChunkState = .New,
    mutex: std.Thread.Mutex = .{},

    pub fn create(alloc: std.mem.Allocator, pos: ChunkCoord) !*Chunk {
        const chunk_ptr = alloc.create(Chunk) catch |err| {
            std.log.err("Failed to allocate memory for new chunk!", .{});
            return err;
        };

        for (0..32) |y| {
            for (0..32) |x| {
                for (0..32) |z| {
                    chunk_ptr.blocks[y + (x * 32) + (32 * 32 * z)] = Block.Air;
                }
            }
        }

        chunk_ptr.front_mesh = ChunkMesh.create(alloc) catch |err| {
            std.log.err("Failed to create chunk mesh!", .{});
            alloc.destroy(chunk_ptr);
            return err;
        };

        chunk_ptr.back_mesh = ChunkMesh.create(alloc) catch |err| {
            std.log.err("Failed to create chunk mesh!", .{});
            alloc.destroy(chunk_ptr);
            return err;
        };
        chunk_ptr.pos = pos;
        chunk_ptr.mutex = .{};

        chunk_ptr.state = .New;

        return chunk_ptr;
    }

    pub fn destroy(self: *Chunk, alloc: std.mem.Allocator) void {
        self.front_mesh.destroy(alloc);
        self.back_mesh.destroy(alloc);
        alloc.destroy(self);
    }

    pub fn generate(self: *Chunk, gen: *noize.Gen) void {
        self.mutex.lock();
        genChunk(self, gen);
        self.state = .ToMesh;
        self.mutex.unlock();
    }

    pub fn buildMesh(
        self: *Chunk,
        alloc: std.mem.Allocator,
        neighbours: []?*Chunk,
        cl_context: cl.cl_context,
        cl_queue: cl.cl_command_queue,
        axis_kernel: cl.cl_kernel,
        cull_kernel: cl.cl_kernel,
        greedy_kernel: cl.cl_kernel,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.state = .Meshing;

        self.back_mesh.vertices.clearRetainingCapacity();
        self.back_mesh.indices.clearRetainingCapacity();

        try self.back_mesh.vertices.ensureTotalCapacity(alloc, 8192);
        try self.back_mesh.indices.ensureTotalCapacity(alloc, 8192 * 6);

        var err: cl.cl_int = undefined;
        const blocks_mem = cl.clCreateBuffer(cl_context, cl.CL_MEM_READ_ONLY, 32 * 32 * 32 * @sizeOf(u8), null, &err);
        if (err != cl.CL_SUCCESS) {
            std.log.err("Failed to create blocks buffer: {}", .{err});
            return error.OpenCLBufferCreationFailed;
        }
        defer _ = cl.clReleaseMemObject(blocks_mem);

        const axis_cols_mem = cl.clCreateBuffer(cl_context, cl.CL_MEM_WRITE_ONLY, 3 * 32 * 32 * @sizeOf(u32), null, &err);
        if (err != cl.CL_SUCCESS) {
            std.log.err("Failed to create axis_cols buffer: {}", .{err});
            return error.OpenCLBufferCreationFailed;
        }
        defer _ = cl.clReleaseMemObject(axis_cols_mem);

        const col_face_masks_mem = cl.clCreateBuffer(cl_context, cl.CL_MEM_READ_WRITE, 6 * 32 * 32 * @sizeOf(u32), null, &err);
        if (err != cl.CL_SUCCESS) {
            std.log.err("Failed to create col_face_masks buffer: {}", .{err});
            return error.OpenCLBufferCreationFailed;
        }
        defer _ = cl.clReleaseMemObject(col_face_masks_mem);

        const out_planes_mem = cl.clCreateBuffer(cl_context, cl.CL_MEM_WRITE_ONLY, 6 * 32 * 32 * @sizeOf(u32), null, &err);
        if (err != cl.CL_SUCCESS) {
            std.log.err("Failed to create out planes buffer: {}", .{err});
            return error.OpenCLBufferCreationFailed;
        }
        defer _ = cl.clReleaseMemObject(out_planes_mem);

        // Binary representation for each axis
        // axis_cols[axis][z][x] where axis: 0=Y, 1=X, 2=Z
        var axis_cols: [3 * 32 * 32]u32 = undefined;
        @memset(&axis_cols, 0);

        // Upload blocks directly to GPU (Block enum is u8, same as kernel input)
        err = cl.clEnqueueWriteBuffer(cl_queue, blocks_mem, cl.CL_TRUE, // blocking write
            0, 32 * 32 * 32 * @sizeOf(u8), &self.blocks, 0, null, null);
        if (err != cl.CL_SUCCESS) {
            std.log.err("Failed to write blocks buffer: {}", .{err});
            return error.OpenCLBufferWriteFailed;
        }

        // Zero out the persistent axis_cols buffer
        const zero: u32 = 0;
        err = cl.clEnqueueFillBuffer(
            cl_queue,
            axis_cols_mem,
            &zero,
            @sizeOf(u32),
            0,
            @sizeOf(u32) * 3 * 32 * 32,
            0,
            null,
            null,
        );
        if (err != cl.CL_SUCCESS) {
            std.log.err("Failed to fill axis_cols buffer: {}", .{err});
            return error.OpenCLBufferFillFailed;
        }

        // Set kernel arguments
        err = cl.clSetKernelArg(axis_kernel, 0, @sizeOf(cl.cl_mem), @ptrCast(&blocks_mem));
        if (err != cl.CL_SUCCESS) {
            std.log.err("Failed to set kernel arg 0: {}", .{err});
            return error.OpenCLKernelArgFailed;
        }

        err = cl.clSetKernelArg(axis_kernel, 1, @sizeOf(cl.cl_mem), @ptrCast(&axis_cols_mem));
        if (err != cl.CL_SUCCESS) {
            std.log.err("Failed to set kernel arg 1: {}", .{err});
            return error.OpenCLKernelArgFailed;
        }

        // Execute kernel with 32x32x32 work items
        const global_work_size = [3]usize{ 32, 32, 32 };
        err = cl.clEnqueueNDRangeKernel(
            cl_queue,
            axis_kernel,
            3,
            null,
            &global_work_size,
            null,
            0,
            null,
            null,
        );
        if (err != cl.CL_SUCCESS) {
            std.log.err("Failed to enqueue kernel: {}", .{err});
            return error.OpenCLKernelExecutionFailed;
        }

        // Read back results
        err = cl.clEnqueueReadBuffer(
            cl_queue,
            axis_cols_mem,
            cl.CL_TRUE, // blocking read
            0,
            @sizeOf(u32) * 3 * 32 * 32,
            &axis_cols,
            0,
            null,
            null,
        );
        if (err != cl.CL_SUCCESS) {
            std.log.err("Failed to read axis_cols buffer: {}", .{err});
            return error.OpenCLBufferReadFailed;
        }

        // Face culling masks for 6 faces
        var col_face_masks: [6 * 32 * 32]u32 = undefined;
        @memset(&col_face_masks, 0);

        // Generate face masks by comparing adjacent voxels
        err = cl.clEnqueueWriteBuffer(cl_queue, axis_cols_mem, cl.CL_TRUE, // blocking write
            0, 3 * 32 * 32 * @sizeOf(u32), &axis_cols, 0, null, null);
        if (err != cl.CL_SUCCESS) {
            std.log.err("Failed to write axis cols buffer: {}", .{err});
            return error.OpenCLBufferWriteFailed;
        }

        err = cl.clEnqueueFillBuffer(cl_queue, col_face_masks_mem, &zero, @sizeOf(u32), 0, @sizeOf(u32) * 6 * 32 * 32, 0, null, null);
        if (err != cl.CL_SUCCESS) {
            std.log.err("Failed to fill col face buffer: {}", .{err});
            return error.OpenCLBufferFillFailed;
        }

        err = cl.clSetKernelArg(cull_kernel, 0, @sizeOf(cl.cl_mem), @ptrCast(&axis_cols_mem));
        if (err != cl.CL_SUCCESS) {
            std.log.err("Failed to set kernel arg 0: {}", .{err});
            return error.OpenCLKernelArgFailed;
        }

        err = cl.clSetKernelArg(cull_kernel, 1, @sizeOf(cl.cl_mem), @ptrCast(&col_face_masks_mem));
        if (err != cl.CL_SUCCESS) {
            std.log.err("Failed to set kernel arg 1: {}", .{err});
            return error.OpenCLKernelArgFailed;
        }

        const cull_work_size = [3]usize{ 3, 32, 32 };
        err = cl.clEnqueueNDRangeKernel(cl_queue, cull_kernel, 3, null, &cull_work_size, null, 0, null, null);
        if (err != cl.CL_SUCCESS) {
            std.log.err("Failed to enqueue kernel: {}", .{err});
            return error.OpenCLKernelExecutionFailed;
        }

        err = cl.clEnqueueReadBuffer(
            cl_queue,
            col_face_masks_mem,
            cl.CL_TRUE,
            0,
            @sizeOf(u32) * 6 * 32 * 32,
            &col_face_masks,
            0,
            null,
            null,
        );
        if (err != cl.CL_SUCCESS) {
            std.log.err("Failed to read buffer: {}", .{err});
            return error.OpenCLBufferReadFailed;
        }

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
                    for (0..32) |x| {
                        for (0..32) |z| {
                            const border_idx = x * 32 + z;
                            if (neighbour_border[border_idx] == .Solid) {
                                const bit_pos: u5 = if (face == .PosY) 31 else 0;
                                neighbour_cols[z * 32 + x] |= (@as(u32, 1) << bit_pos);
                            }
                        }
                    }
                } else if (axis == 1) { // X
                    for (0..32) |y| {
                        for (0..32) |z| {
                            const border_idx = y * 32 + z;
                            if (neighbour_border[border_idx] == .Solid) {
                                const bit_pos: u5 = if (face == .PosX) 31 else 0;
                                neighbour_cols[y * 32 + z] |= (@as(u32, 1) << bit_pos);
                            }
                        }
                    }
                } else { // Z
                    for (0..32) |y| {
                        for (0..32) |x| {
                            const border_idx = y * 32 + x;
                            if (neighbour_border[border_idx] == .Solid) {
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

        alloc.free(neighbours);

        // Create planes for greedy meshing
        var planes: [6 * 32 * 32]u32 = undefined;
        @memset(&planes, 0);

        err = cl.clEnqueueWriteBuffer(cl_queue, col_face_masks_mem, cl.CL_TRUE, // blocking write
            0, 6 * 32 * 32 * @sizeOf(u32), &col_face_masks, 0, null, null);
        if (err != cl.CL_SUCCESS) {
            std.log.err("Failed to write col face masks buffer: {}", .{err});
            return error.OpenCLBufferWriteFailed;
        }

        err = cl.clEnqueueFillBuffer(cl_queue, out_planes_mem, &zero, @sizeOf(u32), 0, @sizeOf(u32) * 6 * 32 * 32, 0, null, null);
        if (err != cl.CL_SUCCESS) {
            std.log.err("Failed to fill planes buffer: {}", .{err});
            return error.OpenCLBufferWriteFailed;
        }

        err = cl.clSetKernelArg(greedy_kernel, 0, @sizeOf(cl.cl_mem), @ptrCast(&col_face_masks_mem));
        if (err != cl.CL_SUCCESS) {
            std.log.err("Failed to set kernel arg 0: {}", .{err});
            return error.OpenCLKernelArgFailed;
        }

        err = cl.clSetKernelArg(greedy_kernel, 1, @sizeOf(cl.cl_mem), @ptrCast(&out_planes_mem));
        if (err != cl.CL_SUCCESS) {
            std.log.err("Failed to set kernel arg 1: {}", .{err});
            return error.OpenCLKernelArgFailed;
        }

        const global_size_greedy = [1]usize{6};
        err = cl.clEnqueueNDRangeKernel(
            cl_queue,
            greedy_kernel,
            1,
            null,
            &global_size_greedy,
            null,
            0,
            null,
            null,
        );
        if (err != cl.CL_SUCCESS) {
            std.log.err("Failed to enqueue greedy kernel: {}", .{err});
            return error.OpenCLKernelExecutionFailed;
        }

        err = cl.clEnqueueReadBuffer(
            cl_queue,
            out_planes_mem,
            cl.CL_TRUE, // blocking read
            0,
            @sizeOf(u32) * 6 * 32 * 32,
            &planes,
            0,
            null,
            null,
        );
        if (err != cl.CL_SUCCESS) {
            std.log.err("Failed to read out planes buffer: {}", .{err});
            return error.OpenCLBufferReadFailed;
        }

        // Greedy mesh each face
        const faces = [_]Face{ .NegY, .PosY, .NegX, .PosX, .NegZ, .PosZ };

        var quads = try std.ArrayList(GreedyQuad).initCapacity(alloc, 2048);
        defer quads.deinit(alloc);

        //const greedy_mesh_start = glfw.getTime();
        for (0..6) |face_idx| {
            const face = faces[face_idx];
            const face_base = face_idx * 32 * 32;

            for (0..32) |layer| {
                quads.clearRetainingCapacity();

                const layer_ptr = @as(*[32]u32, @ptrCast(&planes[face_base + (layer * 32)]));
                try greedyMeshBinaryPlane(layer_ptr, &quads, alloc);

                for (quads.items) |quad| {
                    try self.back_mesh.vertices.ensureUnusedCapacity(alloc, 4);
                    quad.appendVertices(&self.back_mesh.vertices, face, @intCast(layer));
                }
            }
        }

        //const greedy_mesh_elapsed = glfw.getTime() - greedy_mesh_start;
        //std.log.info("Greedy mesh: {d}", .{greedy_mesh_elapsed * 1000});

        // Generate indices
        const vertex_count = self.back_mesh.vertices.items.len;
        const quad_count = vertex_count / 4;

        try self.back_mesh.indices.ensureTotalCapacity(alloc, quad_count * 6);
        for (0..quad_count) |i| {
            const base: u32 = @intCast(i * 4);
            for (FACE_INDICES) |idx| {
                self.back_mesh.indices.appendAssumeCapacity(base + idx);
            }
        }

        self.state = .ToUpload;
    }

    pub fn uploadMesh(self: *Chunk) void {
        self.state = .Uploading;

        const new_mesh = self.back_mesh;

        if (new_mesh.vao_handle == 0) gl.glGenVertexArrays(1, &new_mesh.vao_handle);
        gl.glBindVertexArray(new_mesh.vao_handle);

        if (new_mesh.vbo_handle == 0) gl.glGenBuffers(1, &new_mesh.vbo_handle);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, new_mesh.vbo_handle);
        gl.glBufferData(
            gl.GL_ARRAY_BUFFER,
            @intCast(new_mesh.vertices.items.len * @sizeOf(Vertex)),
            new_mesh.vertices.items.ptr,
            gl.GL_DYNAMIC_DRAW,
        );

        if (new_mesh.ebo_handle == 0) gl.glGenBuffers(1, &new_mesh.ebo_handle);
        gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, new_mesh.ebo_handle);
        gl.glBufferData(
            gl.GL_ELEMENT_ARRAY_BUFFER,
            @intCast(new_mesh.indices.items.len * @sizeOf(u32)),
            new_mesh.indices.items.ptr,
            gl.GL_DYNAMIC_DRAW,
        );

        // vertices
        gl.glVertexAttribPointer(0, 3, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(Vertex), null);
        gl.glEnableVertexAttribArray(0);

        // normals
        gl.glVertexAttribPointer(1, 3, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(Vertex), @ptrFromInt(3 * @sizeOf(f32)));
        gl.glEnableVertexAttribArray(1);

        const temp_mesh = self.front_mesh;
        self.front_mesh = new_mesh;
        self.back_mesh = temp_mesh;

        self.state = .Idle;
    }

    pub fn updateBorders(self: *Chunk) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        @memset(&self.border_data, .Air);

        for (0..6) |face_idx| {
            const face: Face = @enumFromInt(face_idx);
            const face_base = face_idx * 32 * 32;

            switch (face) {
                .PosY => {
                    for (0..32) |x| {
                        for (0..32) |z| {
                            const block_idx = 31 + (x * 32) + (32 * 32 * z);
                            const border_idx = face_base + (x * 32) + z;
                            self.border_data[border_idx] = self.blocks[block_idx];
                        }
                    }
                },
                .NegY => {
                    for (0..32) |x| {
                        for (0..32) |z| {
                            const block_idx = 0 + (x * 32) + (32 * 32 * z);
                            const border_idx = face_base + (x * 32) + z;
                            self.border_data[border_idx] = self.blocks[block_idx];
                        }
                    }
                },
                .PosX => {
                    for (0..32) |y| {
                        for (0..32) |z| {
                            const block_idx = y + (31 * 32) + (32 * 32 * z);
                            const border_idx = face_base + (y * 32) + z;
                            self.border_data[border_idx] = self.blocks[block_idx];
                        }
                    }
                },
                .NegX => {
                    for (0..32) |y| {
                        for (0..32) |z| {
                            const block_idx = y + (0 * 32) + (32 * 32 * z);
                            const border_idx = face_base + (y * 32) + z;
                            self.border_data[border_idx] = self.blocks[block_idx];
                        }
                    }
                },
                .PosZ => {
                    for (0..32) |y| {
                        for (0..32) |x| {
                            const block_idx = y + (x * 32) + (31 * 32 * 32);
                            const border_idx = face_base + (y * 32) + x;
                            self.border_data[border_idx] = self.blocks[block_idx];
                        }
                    }
                },
                .NegZ => {
                    for (0..32) |y| {
                        for (0..32) |x| {
                            const block_idx = y + (x * 32) + (0 * 32 * 32);
                            const border_idx = face_base + (y * 32) + x;
                            self.border_data[border_idx] = self.blocks[block_idx];
                        }
                    }
                },
            }
        }
    }

    pub fn getBorderFace(self: *Chunk, face: Face) []Block {
        const face_idx: usize = @intFromEnum(face);
        const face_base: usize = face_idx * 32 * 32;
        return self.border_data[face_base .. face_base + 32 * 32];
    }
};

fn greedyMeshBinaryPlane(data: *[32]u32, quads: *std.ArrayList(GreedyQuad), alloc: std.mem.Allocator) !void {
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

pub const Job = enum {
    Generate,
    Remesh,
    UpdateBorders,
    Destroy,
};

pub const ChunkJob = struct {
    chunks: []u64, // chunk hashes
    kind: Job,
};

pub fn meshWorker(
    world: *World,
) !void {
    while (!world.worker_done.load(.acquire)) {
        world.job_mutex.?.lock();
        const maybe_job = if (world.job_queue.?.items.len > 0) world.job_queue.?.orderedRemove(0) else null;
        world.job_mutex.?.unlock();

        if (maybe_job) |job| {
            if (job.kind == .Generate) {
                for (job.chunks) |hash| {
                    const chunk = world.chunks.get(hash);
                    if (chunk != null) chunk.?.generate(world.gen);
                }

                const borderJob = ChunkJob{
                    .chunks = job.chunks,
                    .kind = .UpdateBorders,
                };

                world.job_mutex.?.lock();
                defer world.job_mutex.?.unlock();
                try world.job_queue.?.append(world.alloc, borderJob);
            } else if (job.kind == .UpdateBorders) {
                for (job.chunks) |hash| {
                    const chunk = world.chunks.get(hash);
                    if (chunk != null) chunk.?.updateBorders();
                }

                const meshJob = ChunkJob{
                    .chunks = job.chunks,
                    .kind = .Remesh,
                };

                // Collect valid neighbors for remeshing
                var neighbour_set = std.AutoHashMap(u64, *Chunk).init(world.alloc);
                defer neighbour_set.deinit();

                world.chunks_mutex.lock();
                for (job.chunks) |hash| {
                    const chunk = world.chunks.get(hash);
                    if (chunk == null) continue;

                    const neighbours = try world.get_neighbours(chunk.?.pos.hash());
                    for (neighbours) |maybe_neighbour| {
                        if (maybe_neighbour) |neighbour| {
                            var in_job = false;
                            for (job.chunks) |hashh| {
                                if (hashh == neighbour.pos.hash()) {
                                    in_job = true;
                                    break;
                                }
                            }

                            if (!in_job) {
                                try neighbour_set.put(neighbour.pos.hash(), neighbour);
                            }
                        }
                    }
                    world.alloc.free(neighbours);
                }
                world.chunks_mutex.unlock();

                if (neighbour_set.count() > 0) {
                    var mesh_neighbours = try world.alloc.alloc(u64, neighbour_set.count());
                    var it = neighbour_set.valueIterator();
                    var i: usize = 0;
                    while (it.next()) |chunk_ptr| {
                        mesh_neighbours[i] = chunk_ptr.*.pos.hash();
                        chunk_ptr.*.state = .ToMesh;
                        i += 1;
                    }

                    const pendingMeshJob = ChunkJob{
                        .chunks = mesh_neighbours,
                        .kind = .Remesh,
                    };

                    world.job_mutex.?.lock();
                    try world.job_queue.?.append(world.alloc, pendingMeshJob);
                    world.job_mutex.?.unlock();
                }

                world.job_mutex.?.lock();
                defer world.job_mutex.?.unlock();
                try world.job_queue.?.append(world.alloc, meshJob);
            } else if (job.kind == .Remesh) {
                for (job.chunks) |hash| {
                    world.chunks_mutex.lock();
                    const chunk = world.chunks.get(hash);
                    if (chunk == null) {
                        world.chunks_mutex.unlock();
                        continue;
                    }
                    const neighbours = try world.get_neighbours(chunk.?.pos.hash());
                    world.chunks_mutex.unlock();

                    try chunk.?.buildMesh(
                        world.alloc,
                        neighbours,
                        world.cl_context,
                        world.cl_queue,
                        world.axis_kernel,
                        world.cull_kernel,
                        world.greedy_kernel,
                    );
                }

                world.alloc.free(job.chunks);
            } else { // destroy
                for (job.chunks) |hash| {
                    const kv = world.chunks.fetchRemove(hash) orelse continue;
                    const chunk = kv.value;
                    chunk.mutex.lock(); // wait until someone is done
                    chunk.mutex.unlock();
                    chunk.destroy(world.alloc);
                }

                world.alloc.free(job.chunks);
            }
        } else {
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }
    }
}
