"""Clean up a 3DGS PLY file for web viewer compatibility.

Fixes:
  - Removes Gaussians with -inf/NaN in scale
  - Removes Gaussians with very low opacity
  - Normalizes rotation quaternions
"""
import argparse
import numpy as np
from plyfile import PlyData, PlyElement


def clean_ply(input_path, output_path, min_opacity_sigmoid=0.05):
    ply = PlyData.read(input_path)
    v = ply["vertex"]
    n_original = len(v["x"])

    # Collect all properties into a structured array
    props = [p.name for p in v.properties]
    data = np.zeros(n_original, dtype=[(p, "f4") for p in props])
    for p in props:
        data[p] = v[p]

    # --- Filter: remove -inf / NaN in scale ---
    scale_valid = np.ones(n_original, dtype=bool)
    for i in range(3):
        s = data[f"scale_{i}"]
        scale_valid &= np.isfinite(s)
    n_inf = (~scale_valid).sum()

    # --- Filter: remove low opacity ---
    op_sigmoid = 1.0 / (1.0 + np.exp(-np.clip(data["opacity"], -20, 20)))
    opacity_valid = op_sigmoid >= min_opacity_sigmoid

    mask = scale_valid & opacity_valid
    data = data[mask]
    n_kept = len(data)

    # --- Fix: normalize rotation quaternions ---
    rot = np.stack([data[f"rot_{i}"] for i in range(4)], axis=-1)
    norms = np.linalg.norm(rot, axis=-1, keepdims=True)
    norms = np.clip(norms, 1e-8, None)
    rot = rot / norms
    for i in range(4):
        data[f"rot_{i}"] = rot[:, i]

    # --- Write output ---
    el = PlyElement.describe(data, "vertex")
    PlyData([el]).write(output_path)

    print(f"Input:   {n_original} Gaussians")
    print(f"Removed: {n_inf} with -inf/NaN scale")
    print(f"Removed: {(~opacity_valid & scale_valid).sum()} with opacity < {min_opacity_sigmoid}")
    print(f"Output:  {n_kept} Gaussians -> {output_path}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("input", help="Input PLY path")
    parser.add_argument("output", help="Output PLY path")
    parser.add_argument("--min_opacity", type=float, default=0.05)
    args = parser.parse_args()
    clean_ply(args.input, args.output, args.min_opacity)