const std = @import("std");
const math = @import("zlm").as(f32);
const glfw = @import("glfw");
const noize = @import("noize");

const Camera = @import("../main.zig").Camera;
const Chunk = @import("../world/chunk.zig").Chunk;
const ChunkJob = @import("../threading/worker.zig").ChunkJob;
const OpenGLContext = @import("../renderer/opengl.zig").OpenGLContext;
const Face = @import("../world/block.zig").Face;
const meshWorker = @import("../threading/worker.zig").meshWorker;
const iVec3 = @import("../util.zig").iVec3;

const gl = @cImport({
    @cInclude("glad/glad.h");
});

const cl = @import("cl").cl;

const Hit = struct {
    chunk_coords: iVec3,
    prev_chunk_coords: iVec3,
    local_coords: [3]usize,
    prev_coords: [3]usize,
};

pub const World = struct {
    alloc: std.mem.Allocator,
    chunks: std.AutoHashMap(u64, *Chunk),
    oc: *OpenGLContext,
    gen: *noize.Gen,
    chunk_radius: u32 = 8,
    max_chunk_height: u32 = 3,

    // multithreading shit
    chunks_mutex: std.Thread.Mutex = .{},
    job_queue: ?std.ArrayList(ChunkJob) = null,
    job_mutex: ?std.Thread.Mutex = null,
    worker_thread: ?std.Thread = null,
    worker_done: std.atomic.Value(bool) = .init(false),

    pub fn init(self: *World) !void {
        self.chunks = .init(self.alloc);

        // noize
        var gen_ptr = try self.alloc.create(noize.Gen);
        gen_ptr.* = .{
            .seed = 6942069, // noice
            .sharpness = 20,
            .zoom = 200,
            .warp_strength = 20,
            .type = .Worley,
            .alloc = self.alloc,
            .oc = self.oc,
        };

        try gen_ptr.init();

        self.gen = gen_ptr;

        self.job_mutex = .{};
        self.chunks_mutex = .{};
        self.job_queue = try .initCapacity(self.alloc, 20);
        self.worker_thread = try std.Thread.spawn(.{}, meshWorker, .{self});
    }

    pub fn deinit(self: *World) void {
        self.worker_done.store(true, .seq_cst);
        self.worker_thread.?.join();

        for (self.job_queue.?.items) |job| {
            for (job.chunks) |hash| {
                const chunk = self.chunks.fetchRemove(hash).?.value;
                chunk.destroy(self.alloc);
            }
        }
        self.job_queue.?.deinit(self.alloc);

        self.gen.deinit();
        self.alloc.destroy(self.gen);

        var it = self.chunks.valueIterator();
        while (it.next()) |chunk_ptr_ptr| {
            const chunk_ptr = chunk_ptr_ptr.*;
            chunk_ptr.destroy(self.alloc);
        }

        self.chunks.deinit();
    }

    pub fn load_chunks(self: *World, cam: *Camera) !void {
        self.chunks_mutex.lock();
        defer self.chunks_mutex.unlock();

        const cam_chunk_x: i32 = @intFromFloat(@floor(cam.pos.x / 32));
        const cam_chunk_z: i32 = @intFromFloat(@floor(cam.pos.z / 32));

        var chunks = try std.ArrayList(u64).initCapacity(self.alloc, 64);

        var x: i32 = -@as(i32, @intCast(self.chunk_radius));
        while (x <= self.chunk_radius) : (x += 1) {
            var z: i32 = -@as(i32, @intCast(self.chunk_radius));
            while (z <= self.chunk_radius) : (z += 1) {
                for (0..self.max_chunk_height) |y| {
                    var coords = iVec3{ .x = cam_chunk_x + x, .y = @intCast(y), .z = cam_chunk_z + z };

                    if (self.chunks.get(coords.hash()) == null) {
                        const chunk = try Chunk.create(self.alloc, coords);

                        chunk.state = .New;

                        try self.chunks.put(coords.hash(), chunk);
                        try chunks.append(self.alloc, chunk.pos.hash());
                    }
                }
            }
        }

        if (chunks.items.len == 0) {
            chunks.deinit(self.alloc);
            return;
        }

        const job = ChunkJob{
            .chunks = try chunks.toOwnedSlice(self.alloc),
            .kind = .Generate,
        };

        self.job_mutex.?.lock();
        defer self.job_mutex.?.unlock();
        try self.job_queue.?.append(self.alloc, job);
    }

    pub fn unload_chunks(self: *World, cam: *Camera) !void {
        self.chunks_mutex.lock();
        defer self.chunks_mutex.unlock();

        const cam_chunk_x: i32 = @intFromFloat(@floor(cam.pos.x / 32));
        const cam_chunk_z: i32 = @intFromFloat(@floor(cam.pos.z / 32));

        var chunks = try std.ArrayList(u64).initCapacity(self.alloc, 32);

        var it = self.chunks.iterator();
        while (it.next()) |entry| {
            const chunk_ptr = entry.value_ptr.*;

            const dist_x = @abs(chunk_ptr.pos.x - cam_chunk_x);
            const dist_z = @abs(chunk_ptr.pos.z - cam_chunk_z);

            if ((dist_x > self.chunk_radius or dist_z > self.chunk_radius) and chunk_ptr.state == .Idle) {
                try chunks.append(self.alloc, entry.key_ptr.*);
            }
        }

        if (chunks.items.len == 0) {
            chunks.deinit(self.alloc);
            return;
        }

        // Collect valid neighbors for remeshing
        var neighbour_set = std.AutoHashMap(u64, *Chunk).init(self.alloc);
        defer neighbour_set.deinit();

        for (chunks.items) |chunk| {
            const neighbors = try self.get_neighbours(chunk);
            for (neighbors) |maybe_neighbour| {
                if (maybe_neighbour) |neighbour| {
                    // Check if this neighbor is also being unloaded
                    var being_unloaded = false;
                    for (chunks.items) |c| {
                        if (c == neighbour.pos.hash()) {
                            being_unloaded = true;
                            break;
                        }
                    }

                    if (!being_unloaded) {
                        try neighbour_set.put(neighbour.pos.hash(), neighbour);
                    }
                }
            }
            self.alloc.free(neighbors);
        }

        if (neighbour_set.count() > 0) {
            var mesh_neighbours = try self.alloc.alloc(u64, neighbour_set.count());
            var neighbour_it = neighbour_set.valueIterator();
            var i: usize = 0;
            while (neighbour_it.next()) |chunk_ptr| {
                mesh_neighbours[i] = chunk_ptr.*.pos.hash();
                chunk_ptr.*.state = .ToMesh;
                i += 1;
            }

            const meshJob = ChunkJob{
                .chunks = mesh_neighbours,
                .kind = .Remesh,
            };

            self.job_mutex.?.lock();
            try self.job_queue.?.append(self.alloc, meshJob);
            self.job_mutex.?.unlock();
        }

        const job = ChunkJob{
            .chunks = try chunks.toOwnedSlice(self.alloc),
            .kind = .Destroy,
        };

        self.job_mutex.?.lock();
        defer self.job_mutex.?.unlock();
        try self.job_queue.?.append(self.alloc, job);
    }

    pub fn get_neighbours(self: *World, hash: u64) ![]?*Chunk {
        var neighbours = try self.alloc.alloc(?*Chunk, 6);

        const chunk = self.chunks.get(hash) orelse return neighbours;

        if (chunk.state == .Destroying) return error.DestroyingChunk;

        for (0..6) |face_idx| {
            const face: Face = @enumFromInt(face_idx);

            switch (face) {
                .PosY => {
                    var neighbour_pos = iVec3{ .x = chunk.pos.x, .y = chunk.pos.y + 1, .z = chunk.pos.z };
                    const chunk_ptr = self.chunks.get(neighbour_pos.hash());

                    if (chunk_ptr == null) neighbours[face_idx] = null else neighbours[face_idx] = chunk_ptr.?;
                },
                .NegY => {
                    var neighbour_pos = iVec3{ .x = chunk.pos.x, .y = chunk.pos.y - 1, .z = chunk.pos.z };
                    const chunk_ptr = self.chunks.get(neighbour_pos.hash());

                    if (chunk_ptr == null) neighbours[face_idx] = null else neighbours[face_idx] = chunk_ptr.?;
                },
                .PosX => {
                    var neighbour_pos = iVec3{ .x = chunk.pos.x + 1, .y = chunk.pos.y, .z = chunk.pos.z };
                    const chunk_ptr = self.chunks.get(neighbour_pos.hash());

                    if (chunk_ptr == null) neighbours[face_idx] = null else neighbours[face_idx] = chunk_ptr.?;
                },
                .NegX => {
                    var neighbour_pos = iVec3{ .x = chunk.pos.x - 1, .y = chunk.pos.y, .z = chunk.pos.z };
                    const chunk_ptr = self.chunks.get(neighbour_pos.hash());

                    if (chunk_ptr == null) neighbours[face_idx] = null else neighbours[face_idx] = chunk_ptr.?;
                },
                .PosZ => {
                    var neighbour_pos = iVec3{ .x = chunk.pos.x, .y = chunk.pos.y, .z = chunk.pos.z + 1 };
                    const chunk_ptr = self.chunks.get(neighbour_pos.hash());

                    if (chunk_ptr == null) neighbours[face_idx] = null else neighbours[face_idx] = chunk_ptr.?;
                },
                .NegZ => {
                    var neighbour_pos = iVec3{ .x = chunk.pos.x, .y = chunk.pos.y, .z = chunk.pos.z - 1 };
                    const chunk_ptr = self.chunks.get(neighbour_pos.hash());

                    if (chunk_ptr == null) neighbours[face_idx] = null else neighbours[face_idx] = chunk_ptr.?;
                },
            }
        }

        return neighbours;
    }

    fn get_block(self: *World, cam: *Camera) ?Hit {
        self.chunks_mutex.lock();
        defer self.chunks_mutex.unlock();

        const ray_origin = cam.pos;
        const ray_dir = math.Vec3.sub(cam.target, cam.pos).normalize();

        const stepX: i32 = if (ray_dir.x >= 0) 1 else -1;
        const stepY: i32 = if (ray_dir.y >= 0) 1 else -1;
        const stepZ: i32 = if (ray_dir.z >= 0) 1 else -1;

        const tDeltaX: f32 = if (ray_dir.x == 0.0) std.math.inf(f32) else 1.0 / @abs(ray_dir.x);
        const tDeltaY: f32 = if (ray_dir.y == 0.0) std.math.inf(f32) else 1.0 / @abs(ray_dir.y);
        const tDeltaZ: f32 = if (ray_dir.z == 0.0) std.math.inf(f32) else 1.0 / @abs(ray_dir.z);

        var tMaxX = if (ray_dir.x == 0.0)
            std.math.inf(f32)
        else blk: {
            const voxelX = @floor(ray_origin.x);
            const boundaryX = if (stepX > 0) voxelX + 1.0 else voxelX;
            break :blk (boundaryX - ray_origin.x) / ray_dir.x;
        };

        var tMaxY = if (ray_dir.y == 0.0)
            std.math.inf(f32)
        else blk: {
            const voxelY = @floor(ray_origin.y);
            const boundaryY = if (stepY > 0) voxelY + 1.0 else voxelY;
            break :blk (boundaryY - ray_origin.y) / ray_dir.y;
        };

        var tMaxZ = if (ray_dir.z == 0.0)
            std.math.inf(f32)
        else blk: {
            const voxelZ = @floor(ray_origin.z);
            const boundaryZ = if (stepZ > 0) voxelZ + 1.0 else voxelZ;
            break :blk (boundaryZ - ray_origin.z) / ray_dir.z;
        };

        var currentX: i32 = @intFromFloat(@floor(ray_origin.x));
        var currentY: i32 = @intFromFloat(@floor(ray_origin.y));
        var currentZ: i32 = @intFromFloat(@floor(ray_origin.z));

        var prevX: i32 = currentX;
        var prevY: i32 = currentY;
        var prevZ: i32 = currentZ;

        var t: f32 = 0.0;
        const max_distance: f32 = 10.0;

        while (t < max_distance) {
            const chunk_x = @divFloor(currentX, 32);
            const chunk_y = @divFloor(currentY, 32);
            const chunk_z = @divFloor(currentZ, 32);

            const local_x: usize = @intCast(@mod(currentX, 32));
            const local_y: usize = @intCast(@mod(currentY, 32));
            const local_z: usize = @intCast(@mod(currentZ, 32));

            var coords = iVec3{ .x = chunk_x, .y = chunk_y, .z = chunk_z };
            if (self.chunks.get(coords.hash())) |chunk_ptr| {
                const block = chunk_ptr.blocks[local_y + (32 * local_x) + (32 * 32 * local_z)];

                if (block.isSolid()) {
                    const prev_chunk_x: i32 = @divFloor(prevX, 32);
                    const prev_chunk_y: i32 = @divFloor(prevY, 32);
                    const prev_chunk_z: i32 = @divFloor(prevZ, 32);

                    const prev_chunk_coords = iVec3{ .x = prev_chunk_x, .y = prev_chunk_y, .z = prev_chunk_z };

                    const prev_x: usize = @intCast(@mod(prevX, 32));
                    const prev_y: usize = @intCast(@mod(prevY, 32));
                    const prev_z: usize = @intCast(@mod(prevZ, 32));

                    return Hit{
                        .chunk_coords = coords,
                        .prev_chunk_coords = prev_chunk_coords,
                        .local_coords = .{ local_x, local_y, local_z },
                        .prev_coords = .{ prev_x, prev_y, prev_z },
                    };
                }
            }

            prevX = currentX;
            prevY = currentY;
            prevZ = currentZ;

            if (tMaxX < tMaxY and tMaxX < tMaxZ) {
                t = tMaxX;
                tMaxX += tDeltaX;
                currentX += stepX;
            } else if (tMaxY < tMaxZ) {
                t = tMaxY;
                tMaxY += tDeltaY;
                currentY += stepY;
            } else {
                t = tMaxZ;
                tMaxZ += tDeltaZ;
                currentZ += stepZ;
            }
        }

        return null;
    }

    pub fn break_block(self: *World, cam: *Camera) !void {
        const hit = self.get_block(cam);
        if (hit == null) return;

        var chunk_coords = hit.?.chunk_coords;
        var chunk_ptr = blk: {
            self.chunks_mutex.lock();
            defer self.chunks_mutex.unlock();
            break :blk self.chunks.get(chunk_coords.hash()) orelse return;
        };

        chunk_ptr.mutex.lock();
        defer chunk_ptr.mutex.unlock();

        chunk_ptr.blocks[hit.?.local_coords[1] + (32 * hit.?.local_coords[0]) + (32 * 32 * hit.?.local_coords[2])] = .Air;

        if (chunk_ptr.state == .Idle) {
            chunk_ptr.state = .ToMesh;

            const chunks = try self.alloc.alloc(u64, 1);
            chunks[0] = chunk_ptr.pos.hash();

            const job = ChunkJob{
                .chunks = chunks,
                .kind = .UpdateBorders,
            };

            self.job_mutex.?.lock();
            defer self.job_mutex.?.unlock();
            try self.job_queue.?.append(self.alloc, job);
        }
    }

    pub fn place_block(self: *World, cam: *Camera) !void {
        const hit = self.get_block(cam);
        if (hit == null) return;

        var chunk_coords = hit.?.prev_chunk_coords;
        var chunk_ptr = blk: {
            self.chunks_mutex.lock();
            defer self.chunks_mutex.unlock();
            break :blk self.chunks.get(chunk_coords.hash()) orelse return;
        };

        chunk_ptr.mutex.lock();
        defer chunk_ptr.mutex.unlock();

        chunk_ptr.blocks[hit.?.prev_coords[1] + (32 * hit.?.prev_coords[0]) + (32 * 32 * hit.?.prev_coords[2])] = .Dirt;

        if (chunk_ptr.state == .Idle) {
            chunk_ptr.state = .ToMesh;

            const chunks = try self.alloc.alloc(u64, 1);
            chunks[0] = chunk_ptr.pos.hash();

            const job = ChunkJob{
                .chunks = chunks,
                .kind = .UpdateBorders,
            };

            self.job_mutex.?.lock();
            self.job_queue.?.append(self.alloc, job) catch {
                std.log.err("Failed to append mesh job to queue!", .{});
            };
            self.job_mutex.?.unlock();
        }
    }
};
