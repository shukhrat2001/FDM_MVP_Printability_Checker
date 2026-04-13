import os
import asyncio
import tempfile
from pathlib import Path
from datetime import datetime, timezone

import trimesh
from fastapi import FastAPI, File, UploadFile, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from analysis.wall_thickness import min_wall_thickness
from analysis.overhangs import overhang_check

app = FastAPI(title="FDM Printability Checker API", version="1.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=r"http://(localhost|127\.0\.0\.1)(:\d+)?",
    allow_methods=["POST", "GET", "OPTIONS"],
    allow_headers=["*"],
)

WALL_THICKNESS_THRESHOLD_MM = 1.2
MAX_FILE_SIZE_BYTES = 50 * 1024 * 1024   # 50 MB per file
MAX_BATCH_FILES = 50
ACCEPTED = {".stl", ".obj", ".ply", ".glb", ".gltf"}


# ── shared analysis logic ─────────────────────────────────────────────────────
def _analyse_mesh(content: bytes, filename: str) -> dict:
    suffix = Path(filename).suffix.lower()

    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
            tmp.write(content)
            tmp_path = tmp.name
        mesh = trimesh.load(tmp_path, force="mesh")
    except Exception as exc:
        return {"filename": filename, "status": "ERROR", "error": str(exc)}
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

    if not isinstance(mesh, trimesh.Trimesh):
        return {"filename": filename, "status": "ERROR",
                "error": "Not a single mesh — export as binary STL."}

    extents = mesh.bounding_box.extents.tolist()
    volume_cm3 = round(float(mesh.volume) / 1000.0, 2) if mesh.volume else None

    mesh_info = {
        "vertices": int(len(mesh.vertices)),
        "faces": int(len(mesh.faces)),
        "is_watertight": bool(mesh.is_watertight),
        "bounding_box_mm": {
            "x": round(extents[0], 2),
            "y": round(extents[1], 2),
            "z": round(extents[2], 2),
        },
        "volume_cm3": volume_cm3,
    }

    wall = min_wall_thickness(mesh)
    overhangs = overhang_check(mesh)

    issues, warnings = [], []

    if wall.get("error"):
        warnings.append(f"Wall thickness check skipped: {wall['error']}")
    elif wall["min_wall_thickness_mm"] < WALL_THICKNESS_THRESHOLD_MM:
        issues.append(
            f"Min wall thickness {wall['min_wall_thickness_mm']} mm is below "
            f"{WALL_THICKNESS_THRESHOLD_MM} mm"
        )

    if not mesh_info["is_watertight"]:
        issues.append("Mesh is not watertight — may cause slicing errors.")

    if overhangs["overhang_percentage"] > 30:
        warnings.append(
            f"{overhangs['overhang_percentage']}% of faces overhang "
            f"> {overhangs['overhang_angle_deg']}° — heavy support material needed."
        )
    elif overhangs["needs_supports"]:
        warnings.append(f"{overhangs['violating_faces']} face(s) may need supports.")

    return {
        "filename": filename,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "process": "FDM",
        "status": "FAIL" if issues else "PASS",
        "issues": issues,
        "warnings": warnings,
        "mesh_info": mesh_info,
        "wall_thickness": wall,
        "overhangs": overhangs,
    }


# ── /health ───────────────────────────────────────────────────────────────────
@app.get("/health")
def health():
    return {"status": "ok", "timestamp": datetime.now(timezone.utc).isoformat()}


# ── /analyze  (single file — free tier) ──────────────────────────────────────
@app.post("/analyze")
async def analyze(file: UploadFile = File(...)):
    filename = file.filename or "upload"
    suffix = Path(filename).suffix.lower()
    if suffix not in ACCEPTED:
        raise HTTPException(400, f"Unsupported format '{suffix}'.")

    content = await file.read()
    if len(content) > MAX_FILE_SIZE_BYTES:
        raise HTTPException(413, "File exceeds 50 MB limit.")

    result = await asyncio.to_thread(_analyse_mesh, content, filename)
    return JSONResponse(result)


# ── /batch  (multi-file — pro tier) ──────────────────────────────────────────
@app.post("/batch")
async def batch(files: list[UploadFile] = File(...)):
    if len(files) > MAX_BATCH_FILES:
        raise HTTPException(400, f"Maximum {MAX_BATCH_FILES} files per batch.")

    # Validate + read all files first (fast, I/O only)
    payloads: list[tuple[bytes, str]] = []
    for f in files:
        filename = f.filename or "upload"
        suffix = Path(filename).suffix.lower()
        if suffix not in ACCEPTED:
            raise HTTPException(400, f"'{filename}': unsupported format '{suffix}'.")
        content = await f.read()
        if len(content) > MAX_FILE_SIZE_BYTES:
            raise HTTPException(413, f"'{filename}' exceeds 50 MB limit.")
        payloads.append((content, filename))

    # Run all analyses concurrently in a thread pool
    results = await asyncio.gather(
        *[asyncio.to_thread(_analyse_mesh, data, name) for data, name in payloads]
    )

    passed  = sum(1 for r in results if r.get("status") == "PASS")
    failed  = sum(1 for r in results if r.get("status") == "FAIL")
    errored = sum(1 for r in results if r.get("status") == "ERROR")

    return JSONResponse({
        "batch_timestamp": datetime.now(timezone.utc).isoformat(),
        "total": len(results),
        "passed": passed,
        "failed": failed,
        "errored": errored,
        "results": list(results),
    })
