// Builds Axis Columns
typedef enum {
    Air = 0,
    Grass = 1,
    Dirt = 2,
} Block;

inline uint blocks_index(uint x, uint y, uint z) {
    return y + (32u * x) + (32u * 32u * z);
}

inline uint axis_index(uint axis, uint row, uint col) {
    return axis * (32u * 32u) + row * 32u + col;
}

__kernel void build_axis_cols(
    __global const uchar* blocks_flat, // each element: 0=Air or 1=Solid, length 32*32*32
    __global uint* axis_cols_flat      // pre-zeroed, length = 3*32*32 (3072)
) {
    const uint gx = get_global_id(0); // x in [0..31]
    const uint gy = get_global_id(1); // y in [0..31]
    const uint gz = get_global_id(2); // z in [0..31]

    if (gx >= 32u || gy >= 32u || gz >= 32u) return;

    const uint bidx = blocks_index(gx, gy, gz);
    const uchar block_val = blocks_flat[bidx];

    // Check if the block is ANY solid (not Air)
    if (block_val != Air) {
        const uint bit_y = (1u << gy);
        const uint bit_x = (1u << gx);
        const uint bit_z = (1u << gz);

        const uint a0 = axis_index(0u, gz, gx);
        const uint a1 = axis_index(1u, gy, gz);
        const uint a2 = axis_index(2u, gy, gx);

        atomic_or((volatile __global uint*)&axis_cols_flat[a0], bit_y);
        atomic_or((volatile __global uint*)&axis_cols_flat[a1], bit_x);
        atomic_or((volatile __global uint*)&axis_cols_flat[a2], bit_z);
    }
}

// Face Culler
__kernel void cull(
    __global const uint* axis_cols,
	__global uint* col_face_masks
) {
    const uint axis = get_global_id(0); // 0..3
    const uint gz = get_global_id(1); // 0..32
    const uint gx = get_global_id(2); // 0..32

	if (axis >= 3 || gz >= 32 || gx >= 32) return;

	const uint col = axis_cols[(axis * 32 * 32) + (gz * 32) + gx];
	const uint base_face = (2 * axis) * 32 * 32;

	// Descending axis (- dir)
	col_face_masks[base_face + (gz * 32) + gx] = col & ~(col << 1);
	// Ascending axis (+ dir)
	col_face_masks[base_face + 32 * 32 + (gz * 32) + gx] = col & ~(col >> 1);
}

// Create planes for greedy meshing
#pragma OPENCL EXTENSIONS cl_khr_byte_addressable_restore : enable

typedef enum {
    NegY = 0, PosY = 1,
	NegX = 2, PosX = 3,
	NegZ = 4, PosZ = 5,
} Face;

__kernel void greedy_mesh(
    __global const uint* col_face_masks,
    __global uint* out_planes,
    __global const uchar* blocks_flat,
    const uchar kind
) {
	const uint face_index = get_global_id(0); // 0..6
    if (face_index >= 6u) return;

    const uint face_base = face_index * 32u * 32u;
	const uint axis = face_index / 2;

	uint planes[32 * 32] = {0};

	if (axis == 0) { // Y axis
		for (uint z = 0u; z < 32u; ++z) {
		    for (uint x = 0u; x < 32u; ++x) {
				uint col = col_face_masks[face_base + z * 32u + x];
				while (col != 0u) {
				    uint y = ctz(col);
					col &= col - 1u;
                    
                    // Verify that the block at this position matches the requested kind
                    // For Y axis (faces pointing Up/Down), we need to check the correct block
                    // face_index 0 = NegY (down), means block is at y. Neighbor is y-1 (Air).
                    // face_index 1 = PosY (up), means block is at y. Neighbor is y+1 (Air).
                    // The 'col' bits represent the position of the SOLID block.
                    if (blocks_flat[blocks_index(x, y, z)] == kind) {
					    planes[y * 32u + x] |= (1u << z);
                    }
				}
			}
		}
	} else if (axis == 1) { // X axis
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

	const uint out_base = face_index * 32u * 32u;
	for (uint i = 0u; i < 32u * 32u; ++i) {
		out_planes[out_base + i] = planes[i];
	}
}
