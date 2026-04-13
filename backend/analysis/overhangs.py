import numpy as np
import trimesh


def overhang_check(mesh: trimesh.Trimesh, max_angle_deg: float = 45.0) -> dict:
    """
    Identify faces whose downward-facing normal exceeds max_angle_deg
    from horizontal (i.e. they overhang and need support).
    """
    gravity = np.array([0.0, 0.0, -1.0])
    normals = mesh.face_normals  # (N, 3) unit vectors

    # Dot product with gravity gives cos(angle_from_down)
    cos_vals = np.clip(normals @ gravity, -1.0, 1.0)
    angle_from_vertical = np.degrees(np.arccos(cos_vals))  # 0° = straight down

    # A face is an overhang if it faces down more than threshold
    overhang_mask = angle_from_vertical < (90.0 - max_angle_deg)
    violating = int(overhang_mask.sum())
    total = int(len(normals))

    pct = round(100.0 * violating / total, 1) if total else 0.0

    return {
        "overhang_angle_deg": max_angle_deg,
        "violating_faces": violating,
        "total_faces": total,
        "overhang_percentage": pct,
        "needs_supports": violating > 0
    }
