#version 430 core
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(std430, binding = 0) buffer AxisCols {
  uint axis_cols[];
};

layout(std430, binding = 1) buffer ColFaceMasks {
  uint col_face_masks[];
};

void main() {
  uvec3 gid = gl_GlobalInvocationID;
  if (gid.x >= 3 || gid.y >= 32 || gid.z >= 32) return;

  const uint col = axis_cols[(gid.x * 32 * 32) + (gid.y * 32) + gid.z];
  const uint base_face = (2 * gid.x) * 32 * 32;

  col_face_masks[base_face + (gid.y * 32) + gid.z] = col & ~(col << 1); // Descending axis
  col_face_masks[base_face + 32 * 32 + (gid.y * 32) + gid.z] = col & ~(col >> 1); // Ascending axis
}
