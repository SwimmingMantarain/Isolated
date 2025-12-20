#version 330 core
out vec4 FragColor;

uniform sampler2D uAtlas;

in vec3 Norm;
in vec3 LightDir;
in vec2 TexID;
in vec2 LocalUV;

void main() {
  vec3 a = normalize(Norm);
  vec3 b = normalize(LightDir);
  float d = max(dot(a, -b), 0.0);

  // Ambient Occulus Rift ;)
  float ao = 1.0;
  if (a.y > 0.9) {
    ao = 1.0; // top face
  } else if (a.y < -0.9) {
    ao = 0.6; // bottom face
  } else if (abs(a.x) > 0.9) {
    ao = 0.85; // x-axis face
  } else {
    ao = 0.9; // z-axis face
  }

  float ambient = 0.7;
  float lighting = ambient + 0.3 * d;
  lighting *= ao;

  float ATLAS_WIDTH = 4096.0;
  float TILE_SIZE = 64.0;
  
  vec2 tiled_local_uv = fract(LocalUV);
  
  vec2 coord = (TexID + tiled_local_uv) * (TILE_SIZE / ATLAS_WIDTH);

  vec4 tex = texture(uAtlas, coord);
  FragColor = tex * lighting;
}
