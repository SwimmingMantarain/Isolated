const std = @import("std");
const glfw = @import("glfw");
const noize = @import("noize");

const Vec3 = @import("../util.zig").Vec3;
const newVec3 = @import("../util.zig").newVec3;

const genChunk = @import("../worldgen/gen.zig").genChunk;
const World = @import("../world/world.zig").World;

const Block = @import("../world/block.zig").Block;
const Face = @import("../world/block.zig").Face;
const ChunkMesh = @import("../world/mesh.zig").ChunkMesh;
const Vertex = @import("../world/mesh.zig").Vertex;
const Chunk = @import("../world/chunk.zig").Chunk;

pub const Job = enum {
    Generate,
    Remesh,
    UpdateBorders,
    Destroy,
};

pub const ChunkJob = struct {
    chunks: []u64, // Chunk hashes
    kind: Job,
};

pub fn chunker(world: *World(4, 1)) !void {
    while (!world.chunker_done.load(.acquire)) {
        const maybe_job = world.job_queue.pop() orelse null;

        if (maybe_job) |job| {
            switch (job.kind) {
                .Generate => {
                    for (job.chunks) |hash| {
                        world.chunks_mutex.lock();
                        var chunk = world.chunks.get(hash) orelse {
                            world.chunks_mutex.unlock();
                            continue;
                        };
                        world.chunks_mutex.unlock();
                        chunk.generate();
                    }

                    const bj = try world.alloc.create(ChunkJob);
                    bj.* = .{
                        .chunks = job.chunks,
                        .kind = .UpdateBorders,
                    };

                    world.job_queue.loop_push(bj);
                },
                .UpdateBorders => {
                    var chunks = try std.ArrayList(u64).initCapacity(world.alloc, 32);
                    defer chunks.deinit(world.alloc);

                    for (job.chunks) |hash| {
                        world.chunks_mutex.lock();
                        var chunk = world.chunks.get(hash) orelse {
                            world.chunks_mutex.unlock();
                            continue;
                        };
                        world.chunks_mutex.unlock();

                        const neighbours = try world.get_neighbours(chunk);
                        defer world.alloc.free(neighbours);
                        chunk.borders(neighbours);

                        try chunks.append(world.alloc, chunk.pos.hash());
                        chunk.mutex.lock();
                        chunk.state = .ToMesh;
                        chunk.mutex.unlock();

                        for (neighbours) |neigh_chunk| {
                            if (neigh_chunk == null) continue;
                            neigh_chunk.?.state = .ToMesh;
                            try chunks.append(world.alloc, neigh_chunk.?.pos.hash());
                        }
                    }

                    const mj = try world.alloc.create(ChunkJob);
                    mj.* = .{
                        .chunks = try chunks.toOwnedSlice(world.alloc),
                        .kind = .Remesh,
                    };

                    world.job_queue.loop_push(mj);
                    world.alloc.free(job.chunks);
                },
                .Remesh => {
                    for (job.chunks) |hash| {
                        world.chunks_mutex.lock();
                        var chunk = world.chunks.get(hash) orelse {
                            world.chunks_mutex.unlock();
                            continue;
                        };
                        world.chunks_mutex.unlock();

                        const neighbours = try world.get_neighbours(chunk);
                        defer world.alloc.free(neighbours);

                        try chunk.mesh(world.alloc, neighbours);

                        world.done_queue.loop_push(hash);
                    }
                    world.alloc.free(job.chunks);
                },
                .Destroy => {
                    for (job.chunks) |hash| {
                        world.chunks_mutex.lock();
                        const kv = world.chunks.fetchRemove(hash) orelse {
                            world.chunks_mutex.unlock();
                            continue;
                        };
                        const chunk = kv.value;

                        chunk.mutex.lock();
                        chunk.mutex.unlock();

                        chunk.destroy(world.alloc);
                        world.chunks_mutex.unlock();
                    }
                    world.alloc.free(job.chunks);
                },
            }

            world.alloc.destroy(job);
        } else {
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }
    }
}
