const std = @import("std");
const glfw = @import("glfw");
const noize = @import("noize");

const Vec3 = @import("../util.zig").Vec3;
const newVec3 = @import("../util.zig").newVec3;

const genChunk = @import("./gen.zig").genChunk;

const gl = @cImport({
    @cInclude("glad/glad.h");
});

const cl = @import("cl").cl;

pub const Block = enum {
    Air,
    Solid,
};

pub const Face = enum { PosY, NegY, PosX, NegX, PosZ, NegZ };

pub const ChunkState = enum {
    Idle,
    Queued,
    Generating,
    Ready,
    New,
    Destroying,
};

pub const ChunkCoord = struct {
    x: i32,
    y: i32,
    z: i32,

    pub fn hash(self: *ChunkCoord) u64 {
        return std.hash.Wyhash.hash(0, @as([*]const u8, @ptrCast(self))[0..@sizeOf(ChunkCoord)]);
    }
};

const FACE_NORMALS = [_]Vec3{
    newVec3(0, 1, 0), // PosY (top)
    newVec3(0, -1, 0), // NegY (bottom)
    newVec3(1, 0, 0), // PosX (right)
    newVec3(-1, 0, 0), // NegX (left)
    newVec3(0, 0, 1), // PosZ (front)
    newVec3(0, 0, -1), // NegZ (back)
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
        genChunk(self, gen);
    }

    pub fn buildMesh(
        self: *Chunk,
        alloc: std.mem.Allocator,
        cl_queue: cl.cl_command_queue,
        axis_kernel: cl.cl_kernel,
        cull_kernel: cl.cl_kernel,
        greedy_kernel: cl.cl_kernel,
        blocks_mem: cl.cl_mem,
        axis_cols_mem: cl.cl_mem,
        col_face_masks_mem: cl.cl_mem,
        out_planes_mem: cl.cl_mem,
    ) !void {
        self.state = .Generating;

        self.back_mesh.vertices.clearRetainingCapacity();
        self.back_mesh.indices.clearRetainingCapacity();

        try self.back_mesh.vertices.ensureTotalCapacity(alloc, 8192);
        try self.back_mesh.indices.ensureTotalCapacity(alloc, 8192 * 6);

        // Binary representation for each axis
        // axis_cols[axis][z][x] where axis: 0=Y, 1=X, 2=Z
        var axis_cols: [3 * 32 * 32]u32 = undefined;
        @memset(&axis_cols, 0);

        // Upload blocks directly to GPU (Block enum is u8, same as kernel input)
        var err: cl.cl_int = undefined;
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

        self.state = .Ready;
    }

    pub fn uploadMesh(self: *Chunk) void {
        const temp_mesh = self.front_mesh;
        self.front_mesh = self.back_mesh;
        self.back_mesh = temp_mesh;

        if (self.front_mesh.vao_handle == 0) gl.glGenVertexArrays(1, &self.front_mesh.vao_handle);
        gl.glBindVertexArray(self.front_mesh.vao_handle);

        if (self.front_mesh.vbo_handle == 0) gl.glGenBuffers(1, &self.front_mesh.vbo_handle);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, self.front_mesh.vbo_handle);
        gl.glBufferData(
            gl.GL_ARRAY_BUFFER,
            @intCast(self.front_mesh.vertices.items.len * @sizeOf(Vertex)),
            self.front_mesh.vertices.items.ptr,
            gl.GL_DYNAMIC_DRAW,
        );

        if (self.front_mesh.ebo_handle == 0) gl.glGenBuffers(1, &self.front_mesh.ebo_handle);
        gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, self.front_mesh.ebo_handle);
        gl.glBufferData(
            gl.GL_ELEMENT_ARRAY_BUFFER,
            @intCast(self.front_mesh.indices.items.len * @sizeOf(u32)),
            self.front_mesh.indices.items.ptr,
            gl.GL_DYNAMIC_DRAW,
        );

        // vertices
        gl.glVertexAttribPointer(0, 3, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(Vertex), null);
        gl.glEnableVertexAttribArray(0);

        // normals
        gl.glVertexAttribPointer(1, 3, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(Vertex), @ptrFromInt(3 * @sizeOf(f32)));
        gl.glEnableVertexAttribArray(1);

        self.state = .Idle;
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

pub fn meshWorker(jobs: *std.ArrayList(*Chunk), done: *std.ArrayList(*Chunk), job_mutex: *std.Thread.Mutex, done_mutex: *std.Thread.Mutex, should_stop: *std.atomic.Value(bool), cl_context: cl.cl_context, cl_queue: cl.cl_command_queue, axis_kernel: cl.cl_kernel, cull_kernel: cl.cl_kernel, greedy_kernel: cl.cl_kernel, gen: *noize.Gen, alloc: std.mem.Allocator) !void {
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

    while (!should_stop.*.raw) {
        job_mutex.lock();
        const maybe_chunk = if (jobs.items.len > 0) jobs.pop() else null;
        job_mutex.unlock();

        if (maybe_chunk) |chunk| {
            chunk.mutex.lock();
            if (chunk.state == .Destroying) {
                chunk.mutex.unlock();
                chunk.destroy(alloc);
                continue;
            }

            if (chunk.state == .New) {
                chunk.generate(gen);
                chunk.state = .Queued;
            }
            chunk.mutex.unlock();

            chunk.mutex.lock();
            if (chunk.state == .Destroying) {
                chunk.mutex.unlock();
                chunk.destroy(alloc);
                continue;
            }

            if (chunk.state == .Queued) {
                chunk.buildMesh(alloc, cl_queue, axis_kernel, cull_kernel, greedy_kernel, blocks_mem, axis_cols_mem, col_face_masks_mem, out_planes_mem) catch |build_err| {
                    std.log.err("Failed to build mesh: {}", .{build_err});
                };
            }
            chunk.mutex.unlock();

            done_mutex.lock();
            try done.append(alloc, chunk);
            done_mutex.unlock();
        } else {
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }
    }
}
