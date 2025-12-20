const std = @import("std");

pub const Vec3 = packed struct {
    x: f32,
    y: f32,
    z: f32,
};

pub const Vec2 = packed struct {
    x: f32,
    y: f32,
};

pub const iVec3 = struct {
    x: i32,
    y: i32,
    z: i32,

    pub fn hash(self: *iVec3) u64 {
        return std.hash.Wyhash.hash(69, @as([*]const u8, @ptrCast(self))[0..@sizeOf(iVec3)]);
    }
};

pub fn newVec3(x: f32, y: f32, z: f32) Vec3 {
    return Vec3{ .x = x, .y = y, .z = z };
}

pub fn newVec2(x: f32, y: f32) Vec2 {
    return Vec2{ .x = x, .y = y };
}

pub const Vec4 = packed struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,
};

pub fn newVec4(x: f32, y: f32, z: f32, w: f32) Vec4 {
    return Vec4{ .x = x, .y = y, .z = z, .w = w };
}

pub fn SPSCQueue(comptime T: type, comptime cap: usize) type {
    return struct {
        const Self = @This();

        buffer: []T,
        head: std.atomic.Value(usize),
        tail: std.atomic.Value(usize),

        const Mask = cap - 1;

        pub fn init(gpa: std.mem.Allocator) !Self {
            var self: Self = undefined;
            self.buffer = try gpa.alloc(T, cap);
            self.head = .init(0);
            self.tail = .init(0);

            return self;
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.buffer);
        }

        pub fn push(self: *Self, value: T) bool {
            const tail = self.tail.load(.monotonic);
            const head = self.head.load(.monotonic);
            const next_tail = tail + 1;

            if (@as(u32, @truncate(next_tail)) & Mask == @as(u32, @truncate(head)) & Mask) {
                return false;
            }

            const pos = @as(u32, @truncate(tail)) & Mask;
            self.buffer[pos] = value;
            self.tail.store(next_tail, .release);
            return true;
        }

        pub fn loop_push(self: *Self, value: T) void {
            var pushed: bool = false;
            while (!pushed) {
                pushed = self.push(value);
                if (!pushed) std.Thread.sleep(std.time.ns_per_ms * 1);
            }
        }

        pub fn pop(self: *Self) ?T {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);

            if (head == tail) return null;

            const pos = @as(u32, @truncate(head)) & Mask;
            const value = self.buffer[pos];
            self.head.store(head + 1, .release);

            return value;
        }
    };
}
