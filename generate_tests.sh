#!/usr/bin/env bash
# Run from anywhere inside the project folder
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/backend/venv/bin/activate"

python3 - <<'PYEOF'
import trimesh, numpy as np
from pathlib import Path

out = Path(__file__).parent / "test_models" if '__file__' in dir() else Path("test_models")
out = Path("test_models")
out.mkdir(exist_ok=True)

# 1. PASS: solid cube 20mm
box = trimesh.creation.box([20, 20, 20])
box.export(str(out / "01_cube_PASS.stl"))
print("✓ 01_cube_PASS.stl")

# 2. FAIL: thin sheet 0.4mm — below 1.2mm wall threshold
thin = trimesh.creation.box([40, 40, 0.4])
thin.export(str(out / "02_thin_sheet_FAIL.stl"))
print("✓ 02_thin_sheet_FAIL.stl")

# 3. WARN: sphere — ~50% of faces overhang >45°
sphere = trimesh.creation.icosphere(subdivisions=3, radius=15)
sphere.export(str(out / "03_sphere_WARN.stl"))
print("✓ 03_sphere_WARN.stl")

# 4. FAIL: thin-walled hollow box built from vertex math (no Blender needed)
import numpy as np
wall = 0.5  # mm — deliberately below 1.2mm threshold
w, h, d = 30, 30, 30
verts = []
faces = []

def add_box(x0,y0,z0,x1,y1,z1):
    i = len(verts)
    verts.extend([
        [x0,y0,z0],[x1,y0,z0],[x1,y1,z0],[x0,y1,z0],
        [x0,y0,z1],[x1,y0,z1],[x1,y1,z1],[x0,y1,z1],
    ])
    faces.extend([
        [i,i+2,i+1],[i,i+3,i+2],   # bottom
        [i+4,i+5,i+6],[i+4,i+6,i+7], # top
        [i,i+1,i+5],[i,i+5,i+4],   # front
        [i+2,i+3,i+7],[i+2,i+7,i+6], # back
        [i+1,i+2,i+6],[i+1,i+6,i+5], # right
        [i+3,i,i+4],[i+3,i+4,i+7],  # left
    ])

# six thin panels forming a hollow shell
add_box(0,    0,    0,    w,    wall, d)     # front face
add_box(0,    h-wall,0,  w,    h,    d)     # back face
add_box(0,    0,    0,    wall, h,    d)     # left face
add_box(w-wall,0,  0,    w,    h,    d)     # right face
add_box(0,    0,    0,    w,    h,    wall) # bottom face
add_box(0,    0,    d-wall,w,  h,    d)     # top face

mesh = trimesh.Trimesh(vertices=np.array(verts), faces=np.array(faces))
mesh.export(str(out / "04_hollow_thin_FAIL.stl"))
print("✓ 04_hollow_thin_FAIL.stl  (0.5mm walls, no Blender needed)")

print(f"\nAll done! Files in: {out.resolve()}/")
print("Upload any of them at http://localhost:5173")
PYEOF