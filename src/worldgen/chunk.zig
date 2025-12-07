const std = @import("std");
const glfw = @import("glfw");
const noize = @import("noize");

const Vec3 = @import("../util.zig").Vec3;
const newVec3 = @import("../util.zig").newVec3;

const genChunk = @import("./gen.zig").genChunk;
const World = @import("./world.zig").World;

const Block = @import("../world/block.zig").Block;
const Face = @import("../world/block.zig").Face;
const ChunkMesh = @import("../world/mesh.zig").ChunkMesh;
const Vertex = @import("../world/mesh.zig").Vertex;
const Chunk = @import("../world/chunk.zig").Chunk;

const cl = @import("cl").cl;

const BIT_MASKS: [32]u32 = blk: {
    var arr: [32]u32 = undefined;
    for (0..32) |i| {
        arr[i] = @as(u32, @intCast(1)) << i;
    }
    break :blk arr;
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
        const normal = Face.normal(face);

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

pub fn greedyMeshBinaryPlane(data: *[32]u32, quads: *std.ArrayList(GreedyQuad), alloc: std.mem.Allocator) !void {
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
