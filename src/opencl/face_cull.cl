__kernel void cull(
    __global const uint* axis_cols,
	__global uint* col_face_masks
) {
    const uint axis = get_global_id(0); // 0..3
    const uint gz = get_global_id(0); // 0..32
    const uint gx = get_global_id(0); // 0..32

	if (axis >= 3 || gz >= 32 || gx >= 32) return;

	const uint col = axis_cols[(axis * 32 * 32) + (gz * 32) + gx];
	const uint base_face = (2 * axis) * 32 * 32;

	// Descending axis (- dir)
	col_face_masks[base_face + (gz * 32) + gx] = col & ~(col << 1);
	// Ascending axis (+ dir)
	col_face_masks[base_face + 32 * 32 + (gz * 32) + gx] = col & ~(col >> 1);
}
