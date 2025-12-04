typedef enum {
    Air = 0,
    Solid = 1,
} Block;

inline uint blocks_index(uint x, uint y, uint z) {
    return y + (32u * x) + (32u * 32u * z);
}

inline uint axis_index(uint axis, uint row, uint col) {
    return axis * (32u * 32u) + row * 32u + col;
}

__kernel void build_axis_cols(
    __global const uchar* blocks_flat, // each element: 0=Air or 1=Solid, length 32*32*32
    __global uint* axis_cols_flat     // pre-zeroed, length = 3*32*32 (3072)
) {
    const uint gx = get_global_id(0); // x in [0..31]
    const uint gy = get_global_id(1); // y in [0..31]
    const uint gz = get_global_id(2); // z in [0..31]

    if (gx >= 32u || gy >= 32u || gz >= 32u) return;

    const uint bidx = blocks_index(gx, gy, gz);
    const uchar block_val = blocks_flat[bidx];

    if (block_val == Solid) {
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
