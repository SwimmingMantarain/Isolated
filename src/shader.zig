const std = @import("std");

const gl = @cImport({
    @cInclude("glad/glad.h");
});

pub const Shader = struct {
    id: u32,

    pub fn new() ?Shader {
        // vertex shader
        const vertexShaderSrc = @embedFile("./vertex.glsl");
        const vertexShader = gl.glCreateShader(gl.GL_VERTEX_SHADER);
        gl.glShaderSource(vertexShader, 1, &vertexShaderSrc.ptr, null);
        gl.glCompileShader(vertexShader);

        var sucess: c_int = 0;
        gl.glGetShaderiv(vertexShader, gl.GL_COMPILE_STATUS, &sucess);

        if (sucess == 0) {
            var infoLog: [512]u8 = undefined;
            gl.glGetShaderInfoLog(vertexShader, 512, null, &infoLog);
            std.log.err("Vertex shader compilation failed: {s}", .{infoLog});
            return null;
        }

        // fragment shader
        const fragmentShaderSrc = @embedFile("./fragment.glsl");
        const fragmentShader = gl.glCreateShader(gl.GL_FRAGMENT_SHADER);
        gl.glShaderSource(fragmentShader, 1, &fragmentShaderSrc.ptr, null);
        gl.glCompileShader(fragmentShader);

        gl.glGetShaderiv(fragmentShader, gl.GL_COMPILE_STATUS, &sucess);

        if (sucess == 0) {
            var infoLog: [512]u8 = undefined;
            gl.glGetShaderInfoLog(fragmentShader, 512, null, &infoLog);
            std.log.err("Fragment shader compilation failed: {s}", .{infoLog});
            gl.glDeleteShader(vertexShader);
            return null;
        }

        // shader program
        const shader = gl.glCreateProgram();
        gl.glAttachShader(shader, vertexShader);
        gl.glAttachShader(shader, fragmentShader);
        gl.glLinkProgram(shader);

        gl.glGetProgramiv(shader, gl.GL_LINK_STATUS, &sucess);
        if (sucess == 0) {
            var infoLog: [512]u8 = undefined;
            gl.glGetProgramInfoLog(shader, 512, null, &infoLog);
            std.log.err("Failed to link shader: {s}", .{infoLog});
            gl.glDeleteShader(vertexShader);
            gl.glDeleteShader(fragmentShader);
            return null;
        }

        // cleanup
        gl.glDeleteShader(vertexShader);
        gl.glDeleteShader(fragmentShader);

        return Shader{
            .id = @intCast(shader),
        };
    }

    pub fn use(self: *Shader) void {
        gl.glUseProgram(self.id);
    }
};


