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
