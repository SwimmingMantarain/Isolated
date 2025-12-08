const std = @import("std");
const cl = @import("cl").cl;

pub const OpenCLContext = struct {
    context: cl.cl_context,
    devices: cl.cl_device_id,
    queue: cl.cl_command_queue,
    greedy_program: cl.cl_program,
    axis_kernel: cl.cl_kernel,
    cull_kernel: cl.cl_kernel,
    greedy_kernel: cl.cl_kernel,

    pub fn init(alloc: std.mem.Allocator, devices: cl.cl_device_id) !OpenCLContext {
        // context
        var err: cl.cl_int = undefined;

        const cl_context = cl.clCreateContext(null, 1, &devices, null, null, &err);
        if (err != cl.CL_SUCCESS) return error.OpenCLContextFailed;
        errdefer _ = cl.clReleaseContext(cl_context);

        // command queue
        const queue = cl.clCreateCommandQueue(cl_context, devices, 0, &err);
        if (err != cl.CL_SUCCESS) return error.OpenCLQueueFailed;
        errdefer _ = cl.clReleaseCommandQueue(queue);

        // Greedy Mesher
        const mesh_kernel_src = @embedFile("./greedy_mesh.cl");
        const mesh_program = cl.clCreateProgramWithSource(cl_context, 1, @ptrCast(@constCast(&mesh_kernel_src)), null, &err);
        if (err != cl.CL_SUCCESS or mesh_program == null) return error.OpenCLProgramGreedyFailed;
        errdefer _ = cl.clReleaseProgram(mesh_program);

        err = cl.clBuildProgram(mesh_program, 1, &devices, null, null, null);
        if (err != cl.CL_SUCCESS) {
            var log_size: usize = 0;
            _ = cl.clGetProgramBuildInfo(mesh_program, devices, cl.CL_PROGRAM_BUILD_LOG, 0, null, &log_size);
            const buf = try alloc.alloc(u8, log_size);
            defer alloc.free(buf);
            _ = cl.clGetProgramBuildInfo(mesh_program, devices, cl.CL_PROGRAM_BUILD_LOG, log_size, buf.ptr, null);
            std.log.err("Failed to build program: {s}", .{buf.ptr[0..buf.len]});
            return error.OpenCLProgramBuildFailed;
        }

        const axis_kernel = cl.clCreateKernel(mesh_program, "build_axis_cols", &err);
        if (err != cl.CL_SUCCESS) return error.OpenCLCreateAxisKernelFailed;

        const cull_kernel = cl.clCreateKernel(mesh_program, "cull", &err);
        if (err != cl.CL_SUCCESS) return error.OpenCLCreateCullKernelFailed;

        const greedy_kernel = cl.clCreateKernel(mesh_program, "greedy_mesh", &err);
        if (err != cl.CL_SUCCESS) return error.OpenCLCreateGreedyKernelFailed;

        return OpenCLContext{
            .context = cl_context,
            .devices = devices,
            .queue = queue,
            .greedy_program = mesh_program,
            .axis_kernel = axis_kernel,
            .cull_kernel = cull_kernel,
            .greedy_kernel = greedy_kernel,
        };
    }

    pub fn deinit(self: *OpenCLContext) void {
        _ = cl.clReleaseProgram(self.greedy_program);
        _ = cl.clReleaseCommandQueue(self.queue);
        _ = cl.clReleaseContext(self.context);
    }

    pub fn createMem(self: *OpenCLContext, flags: u64, size: u64) !cl.cl_mem {
        var err: cl.cl_int = undefined;
        const mem = cl.clCreateBuffer(self.context, flags, size, null, &err);
        if (err != cl.CL_SUCCESS) return error.OpenCLBufferCreationFailed;
        return mem;
    }

    pub fn writeMem(self: *OpenCLContext, buffer: cl.cl_mem, size: u64, ptr: ?*anyopaque) !void {
        var err: cl.cl_int = undefined;
        err = cl.clEnqueueWriteBuffer(self.queue, buffer, cl.CL_TRUE, 0, size, ptr, 0, null, null);
        if (err != cl.CL_SUCCESS) return error.OpenCLBufferWriteFailed;
    }

    pub fn readMem(self: *OpenCLContext, buffer: cl.cl_mem, size: u64, ptr: ?*anyopaque) !void {
        var err: cl.cl_int = undefined;
        err = cl.clEnqueueReadBuffer(self.queue, buffer, cl.CL_TRUE, 0, size, ptr, 0, null, null);
        if (err != cl.CL_SUCCESS) return error.OpenCLBufferReadFailed;
    }

    pub fn setKernelArg(_: *OpenCLContext, kernel: cl.cl_kernel, index: u32, arg_size: usize, arg_ptr: ?*const anyopaque) !void {
        var err: cl.cl_int = undefined;
        err = cl.clSetKernelArg(kernel, index, arg_size, arg_ptr);
        if (err != cl.CL_SUCCESS) return error.OpenCLKernelArgFailed;
    }

    pub fn runKernel(self: *OpenCLContext, kernel: cl.cl_kernel, work_size: []const usize) !void {
        var err: cl.cl_int = undefined;
        err = cl.clEnqueueNDRangeKernel(self.queue, kernel, @intCast(work_size.len), null, work_size[0..].ptr, null, 0, null, null);
        if (err != cl.CL_SUCCESS) return error.OpenCLKernelExecutionFailed;
    }
};
