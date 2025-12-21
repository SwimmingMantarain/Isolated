const std = @import("std");
const math = @import("zlm").as(f32);
const glfw = @import("glfw");
const noize = @import("noize");

const Camera = @import("../main.zig").Camera;
const Chunk = @import("../world/chunk.zig").Chunk;
const ChunkJob = @import("../threading/worker.zig").ChunkJob;
// const OpenGLContext = @import("../renderer/opengl.zig").OpenGLContext;
const Face = @import("../world/block.zig").Face;
const chunker = @import("../threading/worker.zig").chunker;
const iVec3 = @import("../util.zig").iVec3;
const Queue = @import("../util.zig").SPSCQueue;

const gl = @cImport({
    @cInclude("glad/glad.h");
});

const Hit = struct {
    chunk_coords: iVec3,
    prev_chunk_coords: iVec3,
    local_coords: [3]usize,
    prev_coords: [3]usize,
};

pub fn World(comptime chunk_radius: usize, comptime world_height: usize) type {
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        camera: *Camera,
        chunks: std.AutoHashMap(u64, *Chunk),
        chunks_mutex: std.Thread.Mutex,
        hjob_queue: Queue(*ChunkJob, 64),
        mjob_queue: Queue(*ChunkJob, 64),
        done_queue: Queue(u64, 64),
        chunker: std.Thread,
        chunker_done: std.atomic.Value(bool) = .init(false),

        const r = chunk_radius;
        const d = r * 2;

        pub fn init(gpa: std.mem.Allocator, camera: *Camera) !*Self {
            var self = try gpa.create(Self);
            self.alloc = gpa;
            self.camera = camera;

            self.chunks = .init(self.alloc);
            self.chunks_mutex = .{};

            self.hjob_queue = try .init(self.alloc);
            self.mjob_queue = try .init(self.alloc);
            self.done_queue = try .init(self.alloc);
            self.chunker = try std.Thread.spawn(.{}, chunker, .{self});

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.chunker_done.store(true, .seq_cst);
            self.chunker.join();

            while (self.hjob_queue.pop()) |job| {
                self.alloc.free(job.chunks);
                self.alloc.destroy(job);
            }
            self.hjob_queue.deinit(self.alloc);

            while (self.mjob_queue.pop()) |job| {
                self.alloc.free(job.chunks);
                self.alloc.destroy(job);
            }
            self.mjob_queue.deinit(self.alloc);
            self.done_queue.deinit(self.alloc);

            var chunks_iter = self.chunks.valueIterator();
            while (chunks_iter.next()) |chunk| {
                chunk.*.destroy(self.alloc);
            }
            self.chunks.deinit();

            self.alloc.destroy(self);
        }

        pub fn load_chunks(self: *Self, cam: *Camera) !void {
            const cam_x: i32 = @intFromFloat(@floor(cam.pos.x / 32));
            const cam_z: i32 = @intFromFloat(@floor(cam.pos.z / 32));

            var chunks = try std.ArrayList(u64).initCapacity(self.alloc, d * d * world_height);
            defer chunks.deinit(self.alloc);

            var x: i32 = -@as(i32, @intCast(chunk_radius));
            while (x <= chunk_radius) : (x += 1) {
                var z: i32 = -@as(i32, @intCast(chunk_radius));
                while (z <= chunk_radius) : (z += 1) {
                    for (0..world_height) |y| {
                        var coords = iVec3{ .x = cam_x + x, .y = @intCast(y), .z = cam_z + z };

                        if (self.chunks.get(coords.hash()) == null) {
                            const chunk = try Chunk.create(self.alloc, coords);
                            chunk.state = .New;

                            try self.chunks.put(chunk.pos.hash(), chunk);

                            try chunks.append(self.alloc, chunk.pos.hash());
                        }
                    }
                }
            }

            if (chunks.items.len == 0) return;

            const job = try self.alloc.create(ChunkJob);
            job.* = .{
                .chunks = try chunks.toOwnedSlice(self.alloc),
                .kind = .Generate,
            };

            self.mjob_queue.loop_push(job);
        }

        pub fn unload_chunks(self: *Self, cam: *Camera) !void {
            const cam_x: i32 = @intFromFloat(@floor(cam.pos.x / 32));
            const cam_z: i32 = @intFromFloat(@floor(cam.pos.z / 32));

            var chunks = try std.ArrayList(u64).initCapacity(self.alloc, 32);
            defer chunks.deinit(self.alloc);

            self.chunks_mutex.lock();
            errdefer self.chunks_mutex.unlock();

            var chunks_iter = self.chunks.valueIterator();
            while (chunks_iter.next()) |chunk| {
                const dist_x = @abs(chunk.*.pos.x - cam_x);
                const dist_z = @abs(chunk.*.pos.z - cam_z);
                const max_dist = @max(dist_x, dist_z);

                if (max_dist > chunk_radius) {
                    chunk.*.mutex.lock();
                    if (chunk.*.state != .Destroying) {
                        chunk.*.state = .Destroying;
                        try chunks.append(self.alloc, chunk.*.pos.hash());
                    }
                    chunk.*.mutex.unlock();
                }
            }

            // Collect neighbour chunks for remeshing
            var neighbour_set = std.AutoHashMap(u64, *Chunk).init(self.alloc);
            defer neighbour_set.deinit();

            for (chunks.items) |hash| {
                const chunk = self.chunks.get(hash) orelse continue;

                const neighbors = try self.get_neighbours(chunk);
                for (neighbors) |maybe_neighbour| {
                    if (maybe_neighbour) |n| {
                        n.mutex.lock();
                        const should_mesh = n.state != .Destroying;
                        n.mutex.unlock();

                        if (self.chunks.get(n.pos.hash())) |_| {
                            if (should_mesh) try neighbour_set.put(n.pos.hash(), n);
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
                    chunk_ptr.*.mutex.lock();
                    chunk_ptr.*.state = .ToMesh;
                    chunk_ptr.*.mutex.unlock();
                    i += 1;
                }

                const job = try self.alloc.create(ChunkJob);
                job.* = .{
                    .chunks = mesh_neighbours,
                    .kind = .Remesh,
                };

                self.mjob_queue.loop_push(job);
            }

            if (chunks.items.len > 0) {
                const dj = try self.alloc.create(ChunkJob);
                dj.* = .{
                    .chunks = try chunks.toOwnedSlice(self.alloc),
                    .kind = .Destroy,
                };

                self.mjob_queue.loop_push(dj);
            }

            self.chunks_mutex.unlock();
        }

        pub fn get_neighbours(self: *Self, chunk: *Chunk) ![]?*Chunk {
            var neighbours = try self.alloc.alloc(?*Chunk, 6);

            for (0..6) |face_idx| {
                const face: Face = @enumFromInt(face_idx);

                switch (face) {
                    .PosY => {
                        var neighbour_pos = iVec3{ .x = chunk.pos.x, .y = chunk.pos.y + 1, .z = chunk.pos.z };
                        const chunk_ptr = self.chunks.get(neighbour_pos.hash());

                        neighbours[face_idx] = chunk_ptr;
                    },
                    .NegY => {
                        var neighbour_pos = iVec3{ .x = chunk.pos.x, .y = chunk.pos.y - 1, .z = chunk.pos.z };
                        const chunk_ptr = self.chunks.get(neighbour_pos.hash());

                        neighbours[face_idx] = chunk_ptr;
                    },
                    .PosX => {
                        var neighbour_pos = iVec3{ .x = chunk.pos.x + 1, .y = chunk.pos.y, .z = chunk.pos.z };
                        const chunk_ptr = self.chunks.get(neighbour_pos.hash());

                        neighbours[face_idx] = chunk_ptr;
                    },
                    .NegX => {
                        var neighbour_pos = iVec3{ .x = chunk.pos.x - 1, .y = chunk.pos.y, .z = chunk.pos.z };
                        const chunk_ptr = self.chunks.get(neighbour_pos.hash());

                        neighbours[face_idx] = chunk_ptr;
                    },
                    .PosZ => {
                        var neighbour_pos = iVec3{ .x = chunk.pos.x, .y = chunk.pos.y, .z = chunk.pos.z + 1 };
                        const chunk_ptr = self.chunks.get(neighbour_pos.hash());

                        neighbours[face_idx] = chunk_ptr;
                    },
                    .NegZ => {
                        var neighbour_pos = iVec3{ .x = chunk.pos.x, .y = chunk.pos.y, .z = chunk.pos.z - 1 };
                        const chunk_ptr = self.chunks.get(neighbour_pos.hash());

                        neighbours[face_idx] = chunk_ptr;
                    },
                }
            }

            return neighbours;
        }

        fn get_block(self: *Self, cam: *Camera) ?Hit {
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

        pub fn break_block(self: *Self, cam: *Camera) !void {
            const hit = self.get_block(cam);
            if (hit == null) return;

            var chunk_coords = hit.?.chunk_coords;
            var chunk_ptr = blk: {
                self.chunks_mutex.lock();
                defer self.chunks_mutex.unlock();
                break :blk self.chunks.get(chunk_coords.hash());
            } orelse return;

            chunk_ptr.mutex.lock();
            defer chunk_ptr.mutex.unlock();

            chunk_ptr.blocks[hit.?.local_coords[1] + (32 * hit.?.local_coords[0]) + (32 * 32 * hit.?.local_coords[2])] = .Air;

            if (chunk_ptr.state == .Idle) {
                chunk_ptr.state = .ToMesh;

                const chunks = try self.alloc.alloc(u64, 1);
                chunks[0] = chunk_ptr.pos.hash();

                const job = try self.alloc.create(ChunkJob);
                job.* = .{
                    .chunks = chunks,
                    .kind = .UpdateBorders,
                };

                self.hjob_queue.loop_push(job);
            }
        }

        pub fn place_block(self: *Self, cam: *Camera) !void {
            const hit = self.get_block(cam);
            if (hit == null) return;

            var chunk_coords = hit.?.prev_chunk_coords;
            var chunk_ptr = blk: {
                self.chunks_mutex.lock();
                defer self.chunks_mutex.unlock();
                break :blk self.chunks.get(chunk_coords.hash());
            } orelse return;

            chunk_ptr.mutex.lock();
            defer chunk_ptr.mutex.unlock();

            chunk_ptr.blocks[hit.?.prev_coords[1] + (32 * hit.?.prev_coords[0]) + (32 * 32 * hit.?.prev_coords[2])] = .Dirt;

            if (chunk_ptr.state == .Idle) {
                chunk_ptr.state = .ToMesh;

                const chunks = try self.alloc.alloc(u64, 1);
                chunks[0] = chunk_ptr.pos.hash();

                const job = try self.alloc.create(ChunkJob);
                job.* = .{
                    .chunks = chunks,
                    .kind = .UpdateBorders,
                };

                self.hjob_queue.loop_push(job);
            }
        }
    };
}
