#version 430 core
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(std430, binding = 0) buffer ColFaceMasks {
  uint col_face_masks[];
};

layout(std430, binding = 1) buffer OutPlanes {
  uint out_planes[];
};

layout(std430, binding = 2) buffer BlocksFlat {
  uint blocks_flat[];
};

uniform uint kind;

// Block types
const uint Air = 0u;
const uint Grass = 1u;
const uint Dirt = 2u;

// Face indices
const uint NegY = 0u;
const uint PosY = 1u;
const uint NegX = 2u;
const uint PosX = 3u;
const uint NegZ = 4u;
const uint PosZ = 5u;

uint blocks_index(uint x, uint y, uint z) {
  return y + (32u * x) + (32u * 32u * z);
}

// Count trailing zeros (equivalent to OpenCL's ctz)
uint ctz(uint x) {
  if (x == 0u) return 32u;
  uint n = 0u;
  if ((x & 0x0000FFFFu) == 0u) {
    n += 16u;
    x >>= 16u;
  }
  if ((x & 0x000000FFu) == 0u) {
    n += 8u;
    x >>= 8u;
  }
  if ((x & 0x0000000Fu) == 0u) {
    n += 4u;
    x >>= 4u;
  }
  if ((x & 0x00000003u) == 0u) {
    n += 2u;
    x >>= 2u;
  }
  if ((x & 0x00000001u) == 0u) {
    n += 1u;
  }
  return n;
}

void main() {
  uint face_index = gl_GlobalInvocationID.x;
  if (face_index >= 6u) return;

  uint face_base = face_index * 32u * 32u;
  uint axis = face_index / 2u;

  // Local array for planes
  uint planes[1024]; // 32 * 32
  for (uint i = 0u; i < 1024u; ++i) {
    planes[i] = 0u;
  }

  if (axis == 0u) { // Y axis
    for (uint z = 0u; z < 32u; ++z) {
      for (uint x = 0u; x < 32u; ++x) {
        uint col = col_face_masks[face_base + z * 32u + x];
        while (col != 0u) {
          uint y = ctz(col);
          col &= col - 1u;

          if (blocks_flat[blocks_index(x, y, z)] == kind) {
            planes[y * 32u + x] |= (1u << z);
          }
        }
      }
    }
  } else if (axis == 1u) { // X axis
    for (uint y = 0u; y < 32u; ++y) {
      for (uint z = 0u; z < 32u; ++z) {
        uint col = col_face_masks[face_base + y * 32u + z];
        while (col != 0u) {
          uint x = ctz(col);
          col &= col - 1u;

          if (blocks_flat[blocks_index(x, y, z)] == kind) {
            planes[x * 32u + y] |= (1u << z);
          }
        }
      }
    }
  } else { // Z axis
    for (uint y = 0u; y < 32u; ++y) {
      for (uint x = 0u; x < 32u; ++x) {
        uint col = col_face_masks[face_base + y * 32u + x];
        while (col != 0u) {
          uint z = ctz(col);
          col &= col - 1u;

          if (blocks_flat[blocks_index(x, y, z)] == kind) {
            planes[z * 32u + x] |= (1u << y);
          }
        }
      }
    }
  }

  // Write out results
  uint out_base = face_index * 32u * 32u;
  for (uint i = 0u; i < 1024u; ++i) {
    out_planes[out_base + i] = planes[i];
  }
}
