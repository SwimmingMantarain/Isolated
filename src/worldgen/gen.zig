const std = @import("std");
const noize = @import("noize");
const cl = @import("cl").cl;
const glfw = @import("glfw");

const Chunk = @import("../world/chunk.zig").Chunk;

pub const Biome = enum(u8) {
    Forest,
    Desert,
    Mountains,

    fn max_height(self: Biome) f64 {
        return switch (self) {
            .Forest => 50.0, // at some point there will be a sea
            .Desert => 45.0,
            .Mountains => 85.0,
        };
    }

    pub fn height(self: Biome, percent: f64) f64 {
        return self.max_height() * percent;
    }
};

pub fn genChunk(chunk: *Chunk, gen: *noize.Gen) void {
    const world_x_offset = chunk.pos.x * 32;
    const world_y_offset = chunk.pos.y * 32;
    const world_z_offset = chunk.pos.z * 32;

    // Biomes
    const chunk_blends = gen.opencl.?.WorleyBlend32x32(gen, Biome, world_x_offset, world_z_offset) catch |err| {
        std.log.err("Failed to run OpenCl biome gen: {s}", .{@errorName(err)});
        return;
    };
    defer gen.alloc.free(chunk_blends);

    // Blocks
    for (0..32) |x| {
        for (0..32) |z| {
            const blends = chunk_blends[((z * 32 + x) * 9)..((z * 32 + x) * 9 + 9)];

            var height: f64 = 0;

            for (blends) |blend| {
                if (blend.biome_id >= 3) {
                    std.log.warn("Invalid biome id {d}", .{blend.biome_id});
                    continue;
                }

                const biome: Biome = @enumFromInt(blend.biome_id);

                height += biome.height(blend.percent);
            }

            if (height <= 1 or std.math.isNan(height)) height = 1;

            for (0..32) |y| {
                const world_y = @as(f64, @floatFromInt(world_y_offset)) + @as(f64, @floatFromInt(y));

                if (world_y < height) {
                    chunk.blocks[y + (32 * x) + (32 * 32 * z)] = .Solid;
                }
            }
        }
    }
}
