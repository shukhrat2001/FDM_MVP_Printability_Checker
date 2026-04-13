import numpy as np
import trimesh


def min_wall_thickness(mesh: trimesh.Trimesh, n_samples: int = 800) -> dict:
    """
    Measure wall thickness via surface ray-casting:
      1. Sample N points on the mesh surface.
      2. At each point, shoot a ray inward along the inward normal.
      3. The distance to the opposite wall = local wall thickness.
      4. Return the minimum and mean across all samples.

    This is accurate for any convex or concave geometry — unlike the
    voxel distance-transform approach, which always reports ~pitch*2
    as the minimum due to surface voxels having distance=1.
    """
    try:
        points, face_idx = trimesh.sample.sample_surface(mesh, n_samples)
        normals = mesh.face_normals[face_idx]   # outward unit normals

        # Nudge origins just inside the surface to avoid self-intersection
        eps = 1e-3
        origins    = points - normals * eps
        directions = -normals                   # shoot inward

        locations, ray_idx, _ = mesh.ray.intersects_location(
            ray_origins=origins,
            ray_directions=directions,
            multiple_hits=False,
        )

        if len(locations) == 0:
            return {
                "min_wall_thickness_mm": None,
                "mean_wall_thickness_mm": None,
                "method": "raycast",
                "error": "No ray exits found — mesh may be non-manifold or open."
            }

        thicknesses = np.linalg.norm(locations - origins[ray_idx], axis=1)

        # Filter grazing near-zero hits and runaway hits larger than the mesh
        max_extent = float(max(mesh.bounding_box.extents))
        valid = thicknesses[(thicknesses > 0.05) & (thicknesses <= max_extent)]

        if valid.size == 0:
            return {
                "min_wall_thickness_mm": None,
                "mean_wall_thickness_mm": None,
                "method": "raycast",
                "error": "All ray hits were filtered as grazing or out-of-bounds."
            }

        return {
            "min_wall_thickness_mm": round(float(valid.min()), 3),
            "mean_wall_thickness_mm": round(float(valid.mean()), 3),
            "method": "raycast",
            "samples": int(valid.size),
            "error": None,
        }

    except Exception as exc:
        return {
            "min_wall_thickness_mm": None,
            "mean_wall_thickness_mm": None,
            "method": "raycast",
            "error": str(exc),
        }
