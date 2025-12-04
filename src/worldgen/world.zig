const std = @import("std");
const math = @import("zlm").as(f32);
const glfw = @import("glfw");
const noize = @import("noize");

const Camera = @import("../main.zig").Camera;
const ChunkCoord = @import("./chunk.zig").ChunkCoord;
const Chunk = @import("./chunk.zig").Chunk;
const meshWorker = @import("./chunk.zig").meshWorker;

const gl = @cImport({
    @cInclude("glad/glad.h");
});

const cl = @import("cl").cl;

const Hit = struct {
    chunk_coords: ChunkCoord,
    prev_chunk_coords: ChunkCoord,
    local_coords: [3]usize,
    prev_coords: [3]usize,
};

pub const World = struct {
    alloc: std.mem.Allocator,
    chunks: std.AutoHashMap(u64, *Chunk),
    cl_context: cl.cl_context,
    cl_device: cl.cl_device_id,
    cl_queue: cl.cl_command_queue,
    axis_kernel: cl.cl_kernel,
    cull_kernel: cl.cl_kernel,
    greedy_kernel: cl.cl_kernel,
    gen: *noize.Gen,
    chunk_radius: u32 = 32,

    // multithreading shit
    job_queue: ?std.ArrayList(*Chunk) = null,
    job_mutex: ?std.Thread.Mutex = null,
    done_queue: ?std.ArrayList(*Chunk) = null,
    done_mutex: ?std.Thread.Mutex = null,
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
            .opencl = .{
                .cl_context = self.cl_context,
                .cl_queue = self.cl_queue,
                .cl_devices = self.cl_device,
            },
        };

        try gen_ptr.init();

        self.gen = gen_ptr;

        self.job_mutex = .{};
        self.done_mutex = .{};
        self.job_queue = try .initCapacity(self.alloc, 30);
        self.done_queue = try .initCapacity(self.alloc, 30);
        self.worker_thread = try std.Thread.spawn(.{}, meshWorker, .{ &self.job_queue.?, &self.done_queue.?, &self.job_mutex.?, &self.done_mutex.?, &self.worker_done, self.cl_context, self.cl_queue, self.axis_kernel, self.cull_kernel, self.greedy_kernel, self.gen, self.alloc });
    }

    pub fn deinit(self: *World) void {
        self.worker_done.store(true, .seq_cst);
        self.worker_thread.?.join();
        self.job_queue.?.deinit(self.alloc);
        self.done_queue.?.deinit(self.alloc);
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
        const cam_chunk_x: i32 = @intFromFloat(@floor(cam.pos.x / 32));
        const cam_chunk_z: i32 = @intFromFloat(@floor(cam.pos.z / 32));

        var x: i32 = -@as(i32, @intCast(self.chunk_radius));
        while (x <= self.chunk_radius) : (x += 1) {
            var z: i32 = -@as(i32, @intCast(self.chunk_radius));
            while (z <= self.chunk_radius) : (z += 1) {
                var coords = ChunkCoord{ .x = cam_chunk_x + x, .y = 0, .z = cam_chunk_z + z };

                if (self.chunks.get(coords.hash()) == null) {
                    const chunk = try Chunk.create(self.alloc, coords);

                    chunk.state = .New;

                    try self.job_queue.?.append(self.alloc, chunk);

                    try self.chunks.put(coords.hash(), chunk);
                }
            }
        }
    }

    pub fn unload_chunks(self: *World, cam: *Camera) !void {
        const cam_chunk_x: i32 = @intFromFloat(@floor(cam.pos.x / 32));
        const cam_chunk_z: i32 = @intFromFloat(@floor(cam.pos.z / 32));

        var to_rm = try std.ArrayList(u64).initCapacity(self.alloc, 20);
        defer to_rm.deinit(self.alloc);

        var it = self.chunks.iterator();
        while (it.next()) |entry| {
            const chunk_ptr = entry.value_ptr.*;

            const dist_x = @abs(chunk_ptr.pos.x - cam_chunk_x);
            const dist_z = @abs(chunk_ptr.pos.z - cam_chunk_z);

            if (dist_x > self.chunk_radius or dist_z > self.chunk_radius) try to_rm.append(self.alloc, entry.key_ptr.*);
        }

        for (to_rm.items) |hash| {
            if (self.chunks.fetchRemove(hash)) |entry| {
                const chunk = entry.value;

                self.job_mutex.?.lock();
                var found_in_queue = false;
                var i: usize = 0;
                while (i < self.job_queue.?.items.len) {
                    if (self.job_queue.?.items[i] == chunk) {
                        _ = self.job_queue.?.orderedRemove(i);
                        found_in_queue = true;
                        break;
                    }
                    i += 1;
                }
                self.job_mutex.?.unlock();

                if (found_in_queue) {
                    chunk.destroy(self.alloc);
                    continue;
                }

                self.done_mutex.?.lock();
                var found_in_done = false;
                i = 0;
                while (i < self.done_queue.?.items.len) {
                    if (self.done_queue.?.items[i] == chunk) {
                        _ = self.done_queue.?.orderedRemove(i);
                        found_in_done = true;
                        break;
                    }
                    i += 1;
                }
                self.done_mutex.?.unlock();

                if (found_in_done) {
                    chunk.destroy(self.alloc);
                    continue;
                }

                chunk.mutex.lock();
                switch (chunk.state) {
                    .Idle, .New => {
                        chunk.mutex.unlock();
                        chunk.destroy(self.alloc);
                    },
                    else => {
                        chunk.state = .Destroying;
                        chunk.mutex.unlock();
                    },
                }
            }
        }
    }

    fn get_block(self: *World, cam: *Camera) ?Hit {
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

            var coords = ChunkCoord{ .x = chunk_x, .y = chunk_y, .z = chunk_z };
            if (self.chunks.get(coords.hash())) |chunk_ptr| {
                const block = chunk_ptr.blocks[local_y + (32 * local_x) + (32 * 32 * local_z)];

                if (block == .Solid) {
                    const prev_chunk_x: i32 = @divFloor(prevX, 32);
                    const prev_chunk_y: i32 = @divFloor(prevY, 32);
                    const prev_chunk_z: i32 = @divFloor(prevZ, 32);

                    const prev_chunk_coords = ChunkCoord{ .x = prev_chunk_x, .y = prev_chunk_y, .z = prev_chunk_z };

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

    pub fn break_block(self: *World, cam: *Camera) void {
        const hit = self.get_block(cam);
        if (hit == null) return;

        var chunk_coords = hit.?.chunk_coords;
        const chunk_ptr = self.chunks.get(chunk_coords.hash()) orelse return;

        chunk_ptr.mutex.lock();
        defer chunk_ptr.mutex.unlock();

        chunk_ptr.blocks[hit.?.local_coords[1] + (32 * hit.?.local_coords[0]) + (32 * 32 * hit.?.local_coords[2])] = .Air;

        if (chunk_ptr.state == .Idle) {
            chunk_ptr.state = .Queued;

            self.job_mutex.?.lock();
            self.job_queue.?.append(self.alloc, chunk_ptr) catch {
                std.log.err("Failed to append mesh job to queue!", .{});
            };
            self.job_mutex.?.unlock();
        }
    }

    pub fn place_block(self: *World, cam: *Camera) void {
        const hit = self.get_block(cam);
        if (hit == null) return;

        var chunk_coords = hit.?.prev_chunk_coords;
        const chunk_ptr = self.chunks.get(chunk_coords.hash()) orelse return;

        chunk_ptr.mutex.lock();
        defer chunk_ptr.mutex.unlock();

        if (chunk_ptr.state == .Destroying) return;

        chunk_ptr.blocks[hit.?.prev_coords[1] + (32 * hit.?.prev_coords[0]) + (32 * 32 * hit.?.prev_coords[2])] = .Solid;

        if (chunk_ptr.state == .Idle) {
            chunk_ptr.state = .Queued;

            self.job_mutex.?.lock();
            self.job_queue.?.append(self.alloc, chunk_ptr) catch {
                std.log.err("Failed to append mesh job to queue!", .{});
            };
            self.job_mutex.?.unlock();
        }
    }
};
