#version 330 core
layout (location = 0) in vec3 aPos;
layout (location = 1) in vec3 aNorm;
layout (location = 2) in vec3 aCol;

uniform mat4 model;
uniform mat4 view;
uniform mat4 proj;
uniform vec3 ldir;

out vec3 Norm;
out vec3 Col;
out vec3 LightDir;

void main() {
    gl_Position = proj * view * model * vec4(aPos, 1.0);
    Norm = mat3(model) * aNorm;
    LightDir = ldir;
    Col = aCol;
}
