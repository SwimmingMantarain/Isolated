#version 430 core
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(std430, binding = 0) buffer Blocks {
  uint blocks_flat[];
};

layout(std430, binding = 1) buffer AxisCols {
  uint axis_cols_flat[];
};

uint blocks_index(uint x, uint y, uint z) {
  return y + (32u * x) + (32u * 32u * z);
}

uint axis_index(uint axis, uint row, uint col) {
  return axis * (32u * 32u) + row * 32u + col;
}

const uint Air = 0u;

void main() {
  uvec3 gid = gl_GlobalInvocationID;
  if (gid.x >= 32 || gid.y >= 32 || gid.z >= 32) return;

  uint bidx = blocks_index(gid.x, gid.y, gid.z);
  uint block = blocks_flat[bidx];

  if (block != Air) {
    uint bit_y = (1u << gid.y);
    uint bit_x = (1u << gid.x);
    uint bit_z = (1u << gid.z);

    uint a0 = axis_index(0u, gid.z, gid.x);
    uint a1 = axis_index(1u, gid.y, gid.z);
    uint a2 = axis_index(2u, gid.y, gid.x);

    atomicOr(axis_cols_flat[a0], bit_y);
    atomicOr(axis_cols_flat[a1], bit_x);
    atomicOr(axis_cols_flat[a2], bit_z);
  }
}
