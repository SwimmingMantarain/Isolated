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
        chunks: []?*Chunk,
        chunks_mutex: std.Thread.Mutex,
        job_queue: Queue(*ChunkJob, 64),
        done_queue: Queue(*Chunk, 64),
        chunker: std.Thread,
        chunker_done: std.atomic.Value(bool) = .init(false),

        const r = chunk_radius;
        const d = r * 2;

        pub fn init(gpa: std.mem.Allocator, camera: *Camera) !*Self {
            var self = try gpa.create(Self);
            self.alloc = gpa;
            self.camera = camera;

            self.chunks = try self.alloc.alloc(?*Chunk, d * d * world_height);
            self.chunks_mutex = .{};
            @memset(self.chunks, null);

            self.job_queue = try .init(self.alloc);
            self.done_queue = try .init(self.alloc);
            self.chunker = try std.Thread.spawn(.{}, chunker, .{self});

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.chunker_done.store(true, .seq_cst);
            self.chunker.join();

            for (self.job_queue.buffer) |job| {
                self.alloc.free(job.chunks);
                self.alloc.destroy(job);
            }
            self.job_queue.deinit(self.alloc);
            self.done_queue.deinit(self.alloc);

            for (self.chunks) |chunk| {
                if (chunk == null) continue;
                chunk.?.destroy(self.alloc);
            }
            self.alloc.free(self.chunks);
        }

        pub fn get_chunk(self: *Self, cam_x: i32, cam_z: i32, x: i32, y: i32, z: i32) ?*Chunk {
            const dx = x - cam_x;
            const dz = z - cam_z;

            if (@abs(dx) >= r or @abs(dz) >= r or y < 0 or y >= world_height) return null;

            const buffer_x = dx + @as(i32, @intCast(r));
            const buffer_z = dz + @as(i32, @intCast(r));

            const index =
                (@as(usize, @intCast(buffer_z)) * d * world_height) +
                (@as(usize, @intCast(buffer_x)) * world_height) +
                (@as(usize, @intCast(y)));

            return self.chunks[index];
        }

        pub fn set_chunk(self: *Self, cam_x: i32, cam_z: i32, x: i32, y: i32, z: i32, chunk: ?*Chunk) bool {
            const dx = x - cam_x;
            const dz = z - cam_z;

            if (@abs(dx) >= r or @abs(dz) >= r or y < 0 or y >= world_height) return false;

            const buffer_x = dx + @as(i32, @intCast(r));
            const buffer_z = dz + @as(i32, @intCast(r));

            const index =
                (@as(usize, @intCast(buffer_z)) * d * world_height) +
                (@as(usize, @intCast(buffer_x)) * world_height) +
                (@as(usize, @intCast(y)));

            self.chunks_mutex.lock();
            self.chunks[index] = chunk;
            self.chunks_mutex.unlock();

            return true;
        }

        pub fn load_chunks(self: *Self, cam: *Camera) !void {
            const cam_chunk_x: i32 = @intFromFloat(@floor(cam.pos.x / 32));
            const cam_chunk_z: i32 = @intFromFloat(@floor(cam.pos.z / 32));

            var chunks = try std.ArrayList(*Chunk).initCapacity(self.alloc, self.chunks.len);

            var x: i32 = -@as(i32, @intCast(chunk_radius));
            while (x <= chunk_radius) : (x += 1) {
                var z: i32 = -@as(i32, @intCast(chunk_radius));
                while (z <= chunk_radius) : (z += 1) {
                    for (0..world_height) |y| {
                        const coords = iVec3{ .x = cam_chunk_x + x, .y = @intCast(y), .z = cam_chunk_z + z };

                        if (self.get_chunk(cam_chunk_x, cam_chunk_z, coords.x, coords.y, coords.z) == null) {
                            const chunk = try Chunk.create(self.alloc, coords);
                            chunk.state = .New;

                            _ = self.set_chunk(cam_chunk_x, cam_chunk_z, coords.x, coords.y, coords.z, chunk);

                            try chunks.append(self.alloc, chunk);
                        }
                    }
                }
            }

            if (chunks.items.len == 0) {
                chunks.deinit(self.alloc);
                return;
            }

            const job = try self.alloc.create(ChunkJob);
            job.* = .{
                .chunks = try chunks.toOwnedSlice(self.alloc),
                .kind = .Generate,
            };

            self.job_queue.loop_push(job);
        }

        pub fn unload_chunks(self: *Self, cam: *Camera) !void {
            const cam_chunk_x: i32 = @intFromFloat(@floor(cam.pos.x / 32));
            const cam_chunk_z: i32 = @intFromFloat(@floor(cam.pos.z / 32));

            var chunks = try std.ArrayList(*Chunk).initCapacity(self.alloc, 32);
            defer chunks.deinit(self.alloc);

            for (self.chunks) |chunk| {
                if (chunk == null) continue;

                const dist_x = @abs(chunk.?.pos.x - cam_chunk_x);
                const dist_z = @abs(chunk.?.pos.z - cam_chunk_z);
                const max_dist = @max(dist_x, dist_z);

                if (max_dist > chunk_radius and chunk.?.state == .Idle) {
                    try chunks.append(self.alloc, chunk.?);
                }
            }

            // Collect neighbour chunks for remeshing
            var neighbour_set = std.AutoHashMap(u64, *Chunk).init(self.alloc);
            defer neighbour_set.deinit();

            for (chunks.items) |chunk| {
                const neighbors = try self.get_neighbours(chunk);
                for (neighbors) |maybe_neighbour| {
                    if (maybe_neighbour) |n| {
                        if (self.get_chunk(cam_chunk_x, cam_chunk_z, n.pos.x, n.pos.y, n.pos.z)) |_| {
                            try neighbour_set.put(n.pos.hash(), n);
                        }
                    }
                }
                self.alloc.free(neighbors);
            }

            if (neighbour_set.count() > 0) {
                var mesh_neighbours = try self.alloc.alloc(*Chunk, neighbour_set.count());
                var neighbour_it = neighbour_set.valueIterator();
                var i: usize = 0;
                while (neighbour_it.next()) |chunk_ptr| {
                    mesh_neighbours[i] = chunk_ptr.*;
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

                self.job_queue.loop_push(job);
            }

            // Destroy chunks outside radius
            if (chunks.items.len > 0) {
                for (chunks.items) |chunk| {
                    chunk.mutex.lock();
                    chunk.state = .Destroying;
                    chunk.mutex.unlock();
                }
            }
        }

        pub fn get_neighbours(self: *Self, chunk: *Chunk) ![]?*Chunk {
            const cam_chunk_x: i32 = @intFromFloat(@floor(self.camera.pos.x / 32));
            const cam_chunk_z: i32 = @intFromFloat(@floor(self.camera.pos.z / 32));

            var neighbours = try self.alloc.alloc(?*Chunk, 6);

            for (0..6) |face_idx| {
                const face: Face = @enumFromInt(face_idx);

                switch (face) {
                    .PosY => {
                        const neighbour_pos = iVec3{ .x = chunk.pos.x, .y = chunk.pos.y + 1, .z = chunk.pos.z };
                        const chunk_ptr = self.get_chunk(cam_chunk_x, cam_chunk_z, neighbour_pos.x, neighbour_pos.y, neighbour_pos.z);

                        neighbours[face_idx] = chunk_ptr;
                    },
                    .NegY => {
                        const neighbour_pos = iVec3{ .x = chunk.pos.x, .y = chunk.pos.y - 1, .z = chunk.pos.z };
                        const chunk_ptr = self.get_chunk(cam_chunk_x, cam_chunk_z, neighbour_pos.x, neighbour_pos.y, neighbour_pos.z);

                        neighbours[face_idx] = chunk_ptr;
                    },
                    .PosX => {
                        const neighbour_pos = iVec3{ .x = chunk.pos.x + 1, .y = chunk.pos.y, .z = chunk.pos.z };
                        const chunk_ptr = self.get_chunk(cam_chunk_x, cam_chunk_z, neighbour_pos.x, neighbour_pos.y, neighbour_pos.z);

                        neighbours[face_idx] = chunk_ptr;
                    },
                    .NegX => {
                        const neighbour_pos = iVec3{ .x = chunk.pos.x - 1, .y = chunk.pos.y, .z = chunk.pos.z };
                        const chunk_ptr = self.get_chunk(cam_chunk_x, cam_chunk_z, neighbour_pos.x, neighbour_pos.y, neighbour_pos.z);

                        neighbours[face_idx] = chunk_ptr;
                    },
                    .PosZ => {
                        const neighbour_pos = iVec3{ .x = chunk.pos.x, .y = chunk.pos.y, .z = chunk.pos.z + 1 };
                        const chunk_ptr = self.get_chunk(cam_chunk_x, cam_chunk_z, neighbour_pos.x, neighbour_pos.y, neighbour_pos.z);

                        neighbours[face_idx] = chunk_ptr;
                    },
                    .NegZ => {
                        const neighbour_pos = iVec3{ .x = chunk.pos.x, .y = chunk.pos.y, .z = chunk.pos.z - 1 };
                        const chunk_ptr = self.get_chunk(cam_chunk_x, cam_chunk_z, neighbour_pos.x, neighbour_pos.y, neighbour_pos.z);

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

            const cam_chunk_x: i32 = @intFromFloat(@floor(cam.pos.x / 32));
            const cam_chunk_z: i32 = @intFromFloat(@floor(cam.pos.z / 32));

            while (t < max_distance) {
                const chunk_x = @divFloor(currentX, 32);
                const chunk_y = @divFloor(currentY, 32);
                const chunk_z = @divFloor(currentZ, 32);

                const local_x: usize = @intCast(@mod(currentX, 32));
                const local_y: usize = @intCast(@mod(currentY, 32));
                const local_z: usize = @intCast(@mod(currentZ, 32));

                const coords = iVec3{ .x = chunk_x, .y = chunk_y, .z = chunk_z };
                if (self.get_chunk(cam_chunk_x, cam_chunk_z, coords.x, coords.y, coords.z)) |chunk_ptr| {
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
            const cam_chunk_x: i32 = @intFromFloat(@floor(cam.pos.x / 32));
            const cam_chunk_z: i32 = @intFromFloat(@floor(cam.pos.z / 32));
            const hit = self.get_block(cam);
            if (hit == null) return;

            const chunk_coords = hit.?.chunk_coords;
            var chunk_ptr = blk: {
                self.chunks_mutex.lock();
                defer self.chunks_mutex.unlock();
                break :blk self.get_chunk(cam_chunk_x, cam_chunk_z, chunk_coords.x, chunk_coords.y, chunk_coords.z) orelse return;
            };

            chunk_ptr.mutex.lock();
            defer chunk_ptr.mutex.unlock();

            chunk_ptr.blocks[hit.?.local_coords[1] + (32 * hit.?.local_coords[0]) + (32 * 32 * hit.?.local_coords[2])] = .Air;

            chunk_ptr.mutex.lock();
            defer chunk_ptr.mutex.unlock();
            if (chunk_ptr.state == .Idle) {
                chunk_ptr.state = .ToMesh;

                const chunks = try self.alloc.alloc(*Chunk, 1);
                chunks[0] = chunk_ptr;

                const job = try self.alloc.create(ChunkJob);
                job.* = .{
                    .chunks = chunks,
                    .kind = .UpdateBorders,
                };

                self.job_queue.loop_push(job);
            }
        }

        pub fn place_block(self: *Self, cam: *Camera) !void {
            const cam_chunk_x: i32 = @intFromFloat(@floor(cam.pos.x / 32));
            const cam_chunk_z: i32 = @intFromFloat(@floor(cam.pos.z / 32));
            const hit = self.get_block(cam);
            if (hit == null) return;

            const chunk_coords = hit.?.prev_chunk_coords;
            var chunk_ptr = blk: {
                self.chunks_mutex.lock();
                defer self.chunks_mutex.unlock();
                break :blk self.get_chunk(cam_chunk_x, cam_chunk_z, chunk_coords.x, chunk_coords.y, chunk_coords.z) orelse return;
            };

            chunk_ptr.mutex.lock();
            defer chunk_ptr.mutex.unlock();

            chunk_ptr.blocks[hit.?.prev_coords[1] + (32 * hit.?.prev_coords[0]) + (32 * 32 * hit.?.prev_coords[2])] = .Dirt;

            chunk_ptr.mutex.lock();
            defer chunk_ptr.mutex.unlock();
            if (chunk_ptr.state == .Idle) {
                chunk_ptr.state = .ToMesh;

                const chunks = try self.alloc.alloc(*Chunk, 1);
                chunks[0] = chunk_ptr;

                const job = try self.alloc.create(ChunkJob);
                job.* = .{
                    .chunks = chunks,
                    .kind = .UpdateBorders,
                };

                self.job_queue.loop_push(job);
            }
        }
    };
}
