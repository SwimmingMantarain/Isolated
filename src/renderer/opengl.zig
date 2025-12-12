const std = @import("std");

const gl = @cImport({
    @cInclude("glad/glad.h");
});

pub const OpenGLContext = struct {
    shader: Program,

    pub fn init() !OpenGLContext {
        // --- VERTEX SHADER ---
        const vsh_src = @embedFile("./vertex.glsl");
        const vsh = gl.glCreateShader(gl.GL_VERTEX_SHADER);

        gl.glShaderSource(vsh, 1, &vsh_src.ptr, null);
        gl.glCompileShader(vsh);

        // check compilation
        var sucess: c_int = 0;
        gl.glGetShaderiv(vsh, gl.GL_COMPILE_STATUS, &sucess);

        if (sucess == 0) {
            var log: [512]u8 = undefined;
            @memset(&log, 0);
            gl.glGetShaderInfoLog(vsh, 512, null, &log);
            std.log.err("Vertex shader compilation failed: {s}", .{log});
            return error.ShaderCompilationFailed;
        }
        defer gl.glDeleteShader(vsh);

        // --- Fragment Shader ---
        const fsh_src = @embedFile("./fragment.glsl");
        const fsh = gl.glCreateShader(gl.GL_FRAGMENT_SHADER);

        gl.glShaderSource(fsh, 1, &fsh_src.ptr, null);
        gl.glCompileShader(fsh);

        // check compilation
        gl.glGetShaderiv(fsh, gl.GL_COMPILE_STATUS, &sucess);

        if (sucess == 0) {
            var log: [512]u8 = undefined;
            @memset(&log, 0);
            gl.glGetShaderInfoLog(fsh, 512, null, &log);
            std.log.err("Fragment shader compilation failed: {s}", .{log});
            return error.ShaderCompilationFailed;
        }
        defer gl.glDeleteShader(fsh);

        // --- Shader Program ---
        var shaders = [2]Shader{
            Shader{ .id = vsh },
            Shader{ .id = fsh },
        };

        const p = try Program.new("OpenGL VF Shaders", shaders[0..]);

        return OpenGLContext{
            .shader = p,
        };
    }

    pub fn newComputeProgram(src: *[:0]const u8, name: []const u8) !Program {
        const shader = try Shader.new(src);
        defer gl.glDeleteShader(shader);
        return try Program.new(name, [1]Shader{shader});
    }
};

pub const Program = struct {
    id: c_uint,

    pub fn new(name: []const u8, shaders: []Shader) !Program {
        const p = gl.glCreateProgram();
        for (shaders) |shader| gl.glAttachShader(p, shader.id);
        gl.glLinkProgram(p);

        var success: c_int = 0;
        gl.glGetProgramiv(p, gl.GL_LINK_STATUS, &success);
        if (success == 0) {
            var log: [512]u8 = undefined;
            @memset(&log, 0);
            gl.glGetProgramInfoLog(p, 512, null, &log);
            std.log.err("Failed to link '{s}' program: {s}", .{ name, log });
        }

        return Program{
            .id = p,
        };
    }

    pub fn use(self: *const Program) void {
        gl.glUseProgram(self.id);
    }
};

pub const Shader = struct {
    id: c_uint,

    pub fn new(src: *[:0]const u8) !Shader {
        const shader = gl.glCreateShader(gl.GL_COMPUTE_SHADER);
        gl.glShaderSource(shader, 1, &src.ptr, null);
        gl.glCompileShader(shader);

        var success: c_int = 0;
        var log: [512]u8 = undefined;
        @memset(&log, 0);

        gl.glGetShaderiv(shader, gl.GL_COMPILE_STATUS, &success);

        if (success != 0) {
            gl.glGetShaderInfoLog(shader, 512, null, &log);
            std.log.err("Failed to compile shader:\n{s}", .{log});
            return error.ShaderCompilationFailed;
        }

        return Shader{
            .id = shader,
        };
    }
};
