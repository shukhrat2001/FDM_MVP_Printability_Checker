#!/usr/bin/env bash
set -e

BOLD="\033[1m"
GREEN="\033[32m"
CYAN="\033[36m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║     FDM Printability Checker — Setup     ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${RESET}"
echo ""

# ── Dependency checks ───────────────────────────────────────────────────────
check_cmd() {
  if ! command -v "$1" &>/dev/null; then
    echo -e "${RED}✗ '$1' not found. $2${RESET}"
    exit 1
  fi
}

check_cmd python3  "Install Python 3.9+ from https://www.python.org"
check_cmd node     "Install Node.js 18+ from https://nodejs.org"
check_cmd npm      "Install Node.js 18+ from https://nodejs.org"

PYTHON_VER=$(python3 -c "import sys; print(sys.version_info[:2] >= (3,9))")
if [ "$PYTHON_VER" != "True" ]; then
  echo -e "${RED}✗ Python 3.9+ required.${RESET}"; exit 1
fi

echo -e "${GREEN}✓ Python3, Node, npm found${RESET}"
echo ""

# ── Project root ─────────────────────────────────────────────────────────────
ROOT="$(cd "$(dirname "$0")" && pwd)"

# ══════════════════════════════════════════════════════════════════════════════
# BACKEND
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}[1/5] Creating backend…${RESET}"
mkdir -p "$ROOT/backend/analysis"

# requirements.txt
cat > "$ROOT/backend/requirements.txt" << 'EOF'
fastapi==0.111.0
uvicorn[standard]==0.30.1
python-multipart==0.0.9
trimesh==4.3.2
numpy==1.26.4
scipy==1.13.1
shapely==2.0.4
rtree==1.2.0
EOF

# ── analysis/wall_thickness.py ──────────────────────────────────────────────
cat > "$ROOT/backend/analysis/wall_thickness.py" << 'EOF'
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
EOF

# ── analysis/overhangs.py ───────────────────────────────────────────────────
cat > "$ROOT/backend/analysis/overhangs.py" << 'EOF'
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
EOF

# ── analysis/__init__.py ────────────────────────────────────────────────────
touch "$ROOT/backend/analysis/__init__.py"

# ── main.py ─────────────────────────────────────────────────────────────────
cat > "$ROOT/backend/main.py" << 'EOF'
import os
import json
import tempfile
import traceback
from pathlib import Path
from datetime import datetime, timezone

import trimesh
import numpy as np
from fastapi import FastAPI, File, UploadFile, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from analysis.wall_thickness import min_wall_thickness
from analysis.overhangs import overhang_check

app = FastAPI(title="FDM Printability Checker API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=r"http://(localhost|127\.0\.0\.1)(:\d+)?",
    allow_methods=["POST", "GET", "OPTIONS"],
    allow_headers=["*"],
)

WALL_THICKNESS_THRESHOLD_MM = 1.2
MAX_FILE_SIZE_BYTES = 50 * 1024 * 1024  # 50 MB


@app.get("/health")
def health():
    return {"status": "ok", "timestamp": datetime.now(timezone.utc).isoformat()}


@app.post("/analyze")
async def analyze(file: UploadFile = File(...)):
    # ── Validate file ──────────────────────────────────────────────────────
    filename = file.filename or "upload"
    suffix = Path(filename).suffix.lower()
    if suffix not in {".stl", ".obj", ".ply", ".glb", ".gltf"}:
        raise HTTPException(
            status_code=400,
            detail=f"Unsupported format '{suffix}'. Accepted: .stl, .obj, .ply, .glb, .gltf"
        )

    content = await file.read()
    if len(content) > MAX_FILE_SIZE_BYTES:
        raise HTTPException(status_code=413, detail="File exceeds 50 MB limit.")

    # ── Save to named temp file with correct extension (critical for trimesh) ─
    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
            tmp.write(content)
            tmp_path = tmp.name

        mesh = trimesh.load(tmp_path, force="mesh")
    except Exception as exc:
        raise HTTPException(status_code=422, detail=f"Could not parse mesh: {exc}")
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass

    if not isinstance(mesh, trimesh.Trimesh):
        raise HTTPException(status_code=422, detail="File did not produce a single mesh (may be a scene). Export as binary STL.")

    # ── Basic mesh stats ──────────────────────────────────────────────────
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

    # ── Geometry checks ───────────────────────────────────────────────────
    wall = min_wall_thickness(mesh)
    overhangs = overhang_check(mesh)

    # ── Pass / Fail logic ─────────────────────────────────────────────────
    issues = []
    warnings = []

    if wall["error"]:
        warnings.append(f"Wall thickness check skipped: {wall['error']}")
    elif wall["min_wall_thickness_mm"] < WALL_THICKNESS_THRESHOLD_MM:
        issues.append(
            f"Min wall thickness {wall['min_wall_thickness_mm']} mm is below {WALL_THICKNESS_THRESHOLD_MM} mm"
        )

    if not mesh_info["is_watertight"]:
        issues.append("Mesh is not watertight — may cause slicing errors.")

    if overhangs["overhang_percentage"] > 30:
        warnings.append(
            f"{overhangs['overhang_percentage']}% of faces overhang > {overhangs['overhang_angle_deg']}° — heavy support material needed."
        )
    elif overhangs["needs_supports"]:
        warnings.append(
            f"{overhangs['violating_faces']} face(s) may need supports."
        )

    status = "FAIL" if issues else "PASS"

    return JSONResponse({
        "filename": filename,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "process": "FDM",
        "status": status,
        "issues": issues,
        "warnings": warnings,
        "mesh_info": mesh_info,
        "wall_thickness": wall,
        "overhangs": overhangs,
    })
EOF

echo -e "${GREEN}✓ Backend files written${RESET}"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# FRONTEND
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}[2/5] Creating frontend…${RESET}"
mkdir -p "$ROOT/frontend/src"

# ── package.json ─────────────────────────────────────────────────────────────
cat > "$ROOT/frontend/package.json" << 'EOF'
{
  "name": "fdm-checker-ui",
  "private": true,
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite --port 5173",
    "build": "vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1"
  },
  "devDependencies": {
    "@vitejs/plugin-react": "^4.3.1",
    "vite": "^5.3.1",
    "tailwindcss": "^3.4.4",
    "postcss": "^8.4.39",
    "autoprefixer": "^10.4.19"
  }
}
EOF

# ── vite.config.js (REQUIRED for JSX) ───────────────────────────────────────
cat > "$ROOT/frontend/vite.config.js" << 'EOF'
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    strictPort: false,   // fall back to next port if 5173 is busy
    proxy: {
      // /api/... → http://localhost:8000/...  (strips /api prefix)
      "/api": {
        target: "http://localhost:8000",
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api/, ""),
      },
    },
  },
});
EOF

# ── tailwind.config.js (REQUIRED for Tailwind) ───────────────────────────────
cat > "$ROOT/frontend/tailwind.config.js" << 'EOF'
/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{js,jsx}"],
  theme: { extend: {} },
  plugins: [],
};
EOF

# ── postcss.config.js (REQUIRED for Tailwind) ─────────────────────────────
cat > "$ROOT/frontend/postcss.config.js" << 'EOF'
export default {
  plugins: {
    tailwindcss: {},
    autoprefixer: {},
  },
};
EOF

# ── index.html ───────────────────────────────────────────────────────────────
cat > "$ROOT/frontend/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>FDM Printability Checker</title>
    <link rel="preconnect" href="https://fonts.googleapis.com" />
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
    <link href="https://fonts.googleapis.com/css2?family=Space+Mono:wght@400;700&family=DM+Sans:wght@300;400;500;600&display=swap" rel="stylesheet" />
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
EOF

# ── src/index.css ─────────────────────────────────────────────────────────────
cat > "$ROOT/frontend/src/index.css" << 'EOF'
@tailwind base;
@tailwind components;
@tailwind utilities;

:root {
  --bg: #0a0a0f;
  --surface: #111118;
  --surface-2: #1a1a24;
  --border: #2a2a3a;
  --accent: #00e5ff;
  --accent-dim: #00e5ff22;
  --pass: #00e676;
  --fail: #ff1744;
  --warn: #ffd740;
  --text: #e8e8f0;
  --text-muted: #6b6b80;
  --mono: 'Space Mono', monospace;
  --sans: 'DM Sans', sans-serif;
}

* { box-sizing: border-box; margin: 0; padding: 0; }

body {
  background: var(--bg);
  color: var(--text);
  font-family: var(--sans);
  min-height: 100vh;
}

@keyframes pulse-ring {
  0% { transform: scale(0.95); opacity: 1; }
  70% { transform: scale(1.15); opacity: 0; }
  100% { transform: scale(0.95); opacity: 0; }
}

@keyframes scan {
  0% { top: 0%; opacity: 0.8; }
  100% { top: 100%; opacity: 0; }
}

@keyframes fade-up {
  from { opacity: 0; transform: translateY(16px); }
  to   { opacity: 1; transform: translateY(0); }
}

@keyframes spin-slow {
  to { transform: rotate(360deg); }
}

.fade-up { animation: fade-up 0.5s ease forwards; }
.fade-up-1 { animation: fade-up 0.5s 0.1s ease both; }
.fade-up-2 { animation: fade-up 0.5s 0.2s ease both; }
.fade-up-3 { animation: fade-up 0.5s 0.3s ease both; }
.fade-up-4 { animation: fade-up 0.5s 0.4s ease both; }

.scanning::after {
  content: '';
  position: absolute;
  left: 0; right: 0;
  height: 2px;
  background: linear-gradient(90deg, transparent, var(--accent), transparent);
  animation: scan 1.4s linear infinite;
}
EOF

# ── src/main.jsx ──────────────────────────────────────────────────────────────
cat > "$ROOT/frontend/src/main.jsx" << 'EOF'
import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App.jsx";
import "./index.css";

ReactDOM.createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
EOF

# ── src/App.jsx ───────────────────────────────────────────────────────────────
cat > "$ROOT/frontend/src/App.jsx" << 'APPEOF'
import { useState, useRef, useCallback } from "react";

// Requests go to /api/... which Vite proxies to http://localhost:8000/...
// This means no CORS issues and no hardcoded port numbers.
const API = "/api";

/* ── tiny icon components ─────────────────────────────────────────────────── */
const Icon = ({ d, size = 20, stroke = "currentColor", fill = "none" }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill={fill}
    stroke={stroke} strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
    <path d={d} />
  </svg>
);

const UploadIcon   = () => <Icon d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4M17 8l-5-5-5 5M12 3v12" />;
const CheckIcon    = () => <Icon d="M20 6 9 17l-5-5" stroke="var(--pass)" />;
const XIcon        = () => <Icon d="M18 6 6 18M6 6l12 12" stroke="var(--fail)" />;
const WarnIcon     = () => <Icon d="M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0zM12 9v4M12 17h.01" stroke="var(--warn)" />;
const CubeIcon     = () => <Icon d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z" />;
const LayersIcon   = () => <Icon d="M12 2 2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5" />;
const RulerIcon    = () => <Icon d="M2 12h20M2 12l4-4m-4 4 4 4M22 12l-4-4m4 4-4 4" />;
const DownloadIcon = () => <Icon d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4M7 10l5 5 5-5M12 15V3" />;

/* ── Metric card ──────────────────────────────────────────────────────────── */
function MetricCard({ label, value, unit, sub, accent, delay = 0 }) {
  return (
    <div className={`fade-up`} style={{ animationDelay: `${delay}ms`, animationFillMode: "both" }}>
      <div style={{
        background: "var(--surface)",
        border: "1px solid var(--border)",
        borderRadius: 12,
        padding: "20px 24px",
        position: "relative",
        overflow: "hidden",
      }}>
        {accent && (
          <div style={{
            position: "absolute", top: 0, left: 0, right: 0, height: 2,
            background: `linear-gradient(90deg, transparent, ${accent}, transparent)`,
          }} />
        )}
        <div style={{ color: "var(--text-muted)", fontSize: 11, fontFamily: "var(--mono)", letterSpacing: "0.1em", textTransform: "uppercase", marginBottom: 8 }}>
          {label}
        </div>
        <div style={{ fontSize: 28, fontWeight: 600, fontFamily: "var(--mono)", color: accent || "var(--text)", lineHeight: 1 }}>
          {value ?? "—"}
          {unit && <span style={{ fontSize: 14, marginLeft: 4, color: "var(--text-muted)" }}>{unit}</span>}
        </div>
        {sub && <div style={{ color: "var(--text-muted)", fontSize: 12, marginTop: 6 }}>{sub}</div>}
      </div>
    </div>
  );
}

/* ── Status badge ─────────────────────────────────────────────────────────── */
function StatusBadge({ status }) {
  const pass = status === "PASS";
  return (
    <div style={{
      display: "inline-flex", alignItems: "center", gap: 8,
      padding: "8px 20px", borderRadius: 999,
      background: pass ? "#00e67618" : "#ff174418",
      border: `1px solid ${pass ? "var(--pass)" : "var(--fail)"}`,
      fontFamily: "var(--mono)", fontWeight: 700, fontSize: 14,
      color: pass ? "var(--pass)" : "var(--fail)",
      letterSpacing: "0.08em",
    }}>
      {pass ? <CheckIcon /> : <XIcon />}
      {status}
    </div>
  );
}

/* ── Issue / warning rows ─────────────────────────────────────────────────── */
function IssueRow({ text, type }) {
  const isIssue = type === "issue";
  return (
    <div style={{
      display: "flex", gap: 10, alignItems: "flex-start",
      padding: "10px 14px", borderRadius: 8, marginBottom: 6,
      background: isIssue ? "#ff174408" : "#ffd74008",
      border: `1px solid ${isIssue ? "#ff174430" : "#ffd74030"}`,
    }}>
      {isIssue ? <XIcon /> : <WarnIcon />}
      <span style={{ fontSize: 13, color: "var(--text)", lineHeight: 1.5 }}>{text}</span>
    </div>
  );
}

/* ── Drop zone ────────────────────────────────────────────────────────────── */
function DropZone({ onFile, file }) {
  const inputRef = useRef();
  const [dragging, setDragging] = useState(false);

  const handleDrop = useCallback((e) => {
    e.preventDefault(); setDragging(false);
    const f = e.dataTransfer.files[0];
    if (f) onFile(f);
  }, [onFile]);

  return (
    <div
      onClick={() => inputRef.current.click()}
      onDragOver={(e) => { e.preventDefault(); setDragging(true); }}
      onDragLeave={() => setDragging(false)}
      onDrop={handleDrop}
      style={{
        border: `2px dashed ${dragging ? "var(--accent)" : "var(--border)"}`,
        borderRadius: 16,
        padding: "48px 32px",
        textAlign: "center",
        cursor: "pointer",
        transition: "all 0.2s",
        background: dragging ? "var(--accent-dim)" : "var(--surface)",
        position: "relative",
        overflow: "hidden",
      }}
    >
      <input
        ref={inputRef}
        type="file"
        accept=".stl,.obj,.ply,.glb,.gltf"
        style={{ display: "none" }}
        onChange={(e) => e.target.files[0] && onFile(e.target.files[0])}
      />

      {/* Decorative corner marks */}
      {["tl","tr","bl","br"].map(c => (
        <div key={c} style={{
          position: "absolute",
          width: 16, height: 16,
          [c.includes("t") ? "top" : "bottom"]: 12,
          [c.includes("l") ? "left" : "right"]: 12,
          borderTop: c.includes("t") ? "2px solid var(--accent)" : "none",
          borderBottom: c.includes("b") ? "2px solid var(--accent)" : "none",
          borderLeft: c.includes("l") ? "2px solid var(--accent)" : "none",
          borderRight: c.includes("r") ? "2px solid var(--accent)" : "none",
          opacity: 0.5,
        }} />
      ))}

      <div style={{ color: "var(--accent)", marginBottom: 12, display: "flex", justifyContent: "center" }}>
        <UploadIcon />
      </div>

      {file ? (
        <>
          <div style={{ fontFamily: "var(--mono)", fontSize: 14, color: "var(--accent)", marginBottom: 4 }}>
            {file.name}
          </div>
          <div style={{ color: "var(--text-muted)", fontSize: 12 }}>
            {(file.size / 1024).toFixed(1)} KB — click or drop to replace
          </div>
        </>
      ) : (
        <>
          <div style={{ fontWeight: 500, marginBottom: 6, fontSize: 15 }}>
            Drop your mesh here
          </div>
          <div style={{ color: "var(--text-muted)", fontSize: 12, fontFamily: "var(--mono)" }}>
            .stl · .obj · .ply · .glb · .gltf — up to 50 MB
          </div>
        </>
      )}
    </div>
  );
}

/* ── Spinner ──────────────────────────────────────────────────────────────── */
function Spinner() {
  return (
    <div style={{ textAlign: "center", padding: "48px 0" }}>
      <div style={{
        width: 48, height: 48, border: "2px solid var(--border)",
        borderTop: "2px solid var(--accent)", borderRadius: "50%",
        animation: "spin-slow 0.9s linear infinite", margin: "0 auto 16px",
      }} />
      <div style={{ fontFamily: "var(--mono)", fontSize: 12, color: "var(--accent)", letterSpacing: "0.1em" }}>
        ANALYZING GEOMETRY
      </div>
      <div style={{ color: "var(--text-muted)", fontSize: 12, marginTop: 6 }}>
        Voxelizing mesh & running checks…
      </div>
    </div>
  );
}

/* ── Results panel ────────────────────────────────────────────────────────── */
function Results({ data }) {
  const { status, mesh_info: m, wall_thickness: w, overhangs: o, issues, warnings } = data;

  const downloadJSON = () => {
    const blob = new Blob([JSON.stringify(data, null, 2)], { type: "application/json" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = `fdm-report-${data.filename.replace(/\.[^.]+$/, "")}.json`;
    a.click();
  };

  return (
    <div style={{ marginTop: 32 }}>
      {/* Header row */}
      <div className="fade-up" style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 24, flexWrap: "wrap", gap: 12 }}>
        <div>
          <div style={{ fontFamily: "var(--mono)", fontSize: 11, color: "var(--text-muted)", letterSpacing: "0.1em", marginBottom: 6 }}>ANALYSIS RESULT</div>
          <StatusBadge status={status} />
        </div>
        <button
          onClick={downloadJSON}
          style={{
            display: "flex", alignItems: "center", gap: 8,
            padding: "8px 16px", borderRadius: 8,
            background: "var(--surface-2)", border: "1px solid var(--border)",
            color: "var(--text-muted)", cursor: "pointer", fontSize: 12,
            fontFamily: "var(--mono)", letterSpacing: "0.05em",
            transition: "all 0.15s",
          }}
          onMouseEnter={e => e.currentTarget.style.borderColor = "var(--accent)"}
          onMouseLeave={e => e.currentTarget.style.borderColor = "var(--border)"}
        >
          <DownloadIcon /> EXPORT JSON
        </button>
      </div>

      {/* Issues & warnings */}
      {(issues.length > 0 || warnings.length > 0) && (
        <div className="fade-up-1" style={{ marginBottom: 24 }}>
          {issues.map((t, i) => <IssueRow key={i} text={t} type="issue" />)}
          {warnings.map((t, i) => <IssueRow key={i} text={t} type="warning" />)}
        </div>
      )}

      {/* Metric grid */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(180px, 1fr))", gap: 12, marginBottom: 24 }}>
        <MetricCard delay={100}
          label="Min Wall" accent={w.min_wall_thickness_mm < 1.2 ? "var(--fail)" : "var(--pass)"}
          value={w.error ? "ERR" : w.min_wall_thickness_mm} unit="mm"
          sub={w.error ? w.error.slice(0, 40) : `mean ${w.mean_wall_thickness_mm} mm`}
        />
        <MetricCard delay={150}
          label="Overhangs" accent={o.overhang_percentage > 30 ? "var(--warn)" : "var(--pass)"}
          value={o.overhang_percentage} unit="%"
          sub={`${o.violating_faces} / ${o.total_faces} faces`}
        />
        <MetricCard delay={200}
          label="Watertight" accent={m.is_watertight ? "var(--pass)" : "var(--fail)"}
          value={m.is_watertight ? "YES" : "NO"}
          sub="mesh integrity"
        />
        <MetricCard delay={250}
          label="Volume" accent="var(--accent)"
          value={m.volume_cm3 ?? "—"} unit="cm³"
          sub={`${(m.vertices / 1000).toFixed(1)}k verts · ${(m.faces / 1000).toFixed(1)}k faces`}
        />
      </div>

      {/* Bounding box */}
      <div className="fade-up-4" style={{
        background: "var(--surface)", border: "1px solid var(--border)",
        borderRadius: 12, padding: "16px 24px",
      }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 12, color: "var(--text-muted)", fontSize: 11, fontFamily: "var(--mono)", letterSpacing: "0.1em" }}>
          <CubeIcon />BOUNDING BOX
        </div>
        <div style={{ display: "flex", gap: 24, fontFamily: "var(--mono)", fontSize: 14 }}>
          {["x","y","z"].map(ax => (
            <div key={ax}>
              <span style={{ color: "var(--text-muted)", marginRight: 6 }}>{ax.toUpperCase()}</span>
              <span style={{ color: "var(--accent)" }}>{m.bounding_box_mm[ax]}</span>
              <span style={{ color: "var(--text-muted)", marginLeft: 2 }}>mm</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

/* ══════════════════════════════════════════════════════════════════════════ */
export default function App() {
  const [file, setFile]     = useState(null);
  const [result, setResult] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError]   = useState(null);

  const analyze = async () => {
    if (!file) return;
    setLoading(true); setResult(null); setError(null);
    try {
      const form = new FormData();
      form.append("file", file);
      const res = await fetch(`${API}/analyze`, { method: "POST", body: form });
      const json = await res.json();
      if (!res.ok) throw new Error(json.detail || "Unknown server error");
      setResult(json);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div style={{ minHeight: "100vh", background: "var(--bg)", padding: "0 0 80px" }}>

      {/* Nav */}
      <header style={{
        borderBottom: "1px solid var(--border)",
        padding: "0 32px",
        display: "flex", alignItems: "center", justifyContent: "space-between",
        height: 56,
        background: "var(--surface)",
        position: "sticky", top: 0, zIndex: 10,
      }}>
        <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
          <LayersIcon />
          <span style={{ fontFamily: "var(--mono)", fontWeight: 700, fontSize: 13, letterSpacing: "0.08em", color: "var(--accent)" }}>
            FDM CHECKER
          </span>
        </div>
        <div style={{ fontFamily: "var(--mono)", fontSize: 11, color: "var(--text-muted)" }}>
          v1.0 · localhost
        </div>
      </header>

      {/* Hero */}
      <div style={{ padding: "56px 32px 0", maxWidth: 680, margin: "0 auto" }}>
        <div className="fade-up" style={{ marginBottom: 8, fontFamily: "var(--mono)", fontSize: 11, color: "var(--accent)", letterSpacing: "0.15em" }}>
          FDM PRINTABILITY ANALYSIS
        </div>
        <h1 className="fade-up-1" style={{
          fontSize: "clamp(28px, 5vw, 44px)", fontWeight: 300, lineHeight: 1.1,
          marginBottom: 12, color: "var(--text)",
        }}>
          Will your model<br />
          <em style={{ fontStyle: "italic", color: "var(--accent)" }}>actually print?</em>
        </h1>
        <p className="fade-up-2" style={{ color: "var(--text-muted)", fontSize: 15, lineHeight: 1.6, marginBottom: 40, maxWidth: 520 }}>
          Upload a mesh file and get instant feedback on wall thickness, overhangs, and mesh integrity — before you waste filament.
        </p>

        {/* Upload */}
        <div className="fade-up-3">
          <DropZone onFile={setFile} file={file} />

          <button
            onClick={analyze}
            disabled={!file || loading}
            style={{
              width: "100%", marginTop: 16,
              padding: "14px 0", borderRadius: 10,
              border: "none", cursor: file && !loading ? "pointer" : "not-allowed",
              fontFamily: "var(--mono)", fontWeight: 700, fontSize: 13, letterSpacing: "0.1em",
              background: file && !loading
                ? "linear-gradient(135deg, var(--accent), #0097a7)"
                : "var(--surface-2)",
              color: file && !loading ? "#000" : "var(--text-muted)",
              transition: "all 0.2s",
            }}
          >
            {loading ? "ANALYZING…" : "ANALYZE MESH"}
          </button>
        </div>

        {/* Error */}
        {error && (
          <div className="fade-up" style={{
            marginTop: 16, padding: "12px 16px", borderRadius: 8,
            background: "#ff174410", border: "1px solid #ff174440",
            color: "var(--fail)", fontFamily: "var(--mono)", fontSize: 13,
          }}>
            ✗ {error}
          </div>
        )}

        {/* Loading */}
        {loading && <Spinner />}

        {/* Results */}
        {result && !loading && <Results data={result} />}
      </div>
    </div>
  );
}
APPEOF

echo -e "${GREEN}✓ Frontend files written${RESET}"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# INSTALL BACKEND
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}[3/5] Installing Python dependencies…${RESET}"
cd "$ROOT/backend"
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip -q
pip install -r requirements.txt -q
deactivate
cd "$ROOT"
echo -e "${GREEN}✓ Python venv ready${RESET}"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# INSTALL FRONTEND
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}[4/5] Installing Node dependencies…${RESET}"
cd "$ROOT/frontend"
npm install --silent
cd "$ROOT"
echo -e "${GREEN}✓ Node modules ready${RESET}"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# LAUNCH SCRIPT
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}[5/5] Writing run.sh…${RESET}"
cat > "$ROOT/run.sh" << 'RUNEOF'
#!/usr/bin/env bash
ROOT="$(cd "$(dirname "$0")" && pwd)"

# ── free ports before starting ───────────────────────────────────────────────
free_port() {
  local port=$1
  local pids
  pids=$(lsof -ti tcp:"$port" 2>/dev/null || true)
  if [ -n "$pids" ]; then
    echo "  Killing stale process(es) on port $port: $pids"
    echo "$pids" | xargs kill -9 2>/dev/null || true
    sleep 0.5
  fi
}

echo "Clearing ports 8000 and 5173…"
free_port 8000
free_port 5173

# ── clean shutdown on Ctrl-C ─────────────────────────────────────────────────
trap 'echo ""; echo "Shutting down…"; kill $(jobs -p) 2>/dev/null; wait 2>/dev/null; echo "Done."; exit 0' INT TERM

# ── backend ───────────────────────────────────────────────────────────────────
echo "Starting backend  → http://localhost:8000"
cd "$ROOT/backend"
source venv/bin/activate
uvicorn main:app --reload --port 8000 2>&1 &

# wait until backend is up (max 15 s)
echo -n "Waiting for backend"
for i in $(seq 1 30); do
  if curl -sf http://localhost:8000/health >/dev/null 2>&1; then
    echo " ✓"
    break
  fi
  echo -n "."
  sleep 0.5
done

# ── frontend ──────────────────────────────────────────────────────────────────
echo "Starting frontend → http://localhost:5173"
cd "$ROOT/frontend"
npm run dev 2>&1 &

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Open: http://localhost:5173"
echo "  API:  http://localhost:8000/docs"
echo "  Press Ctrl-C to stop both servers"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

wait
RUNEOF
chmod +x "$ROOT/run.sh"
echo -e "${GREEN}✓ run.sh created${RESET}"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║           Setup Complete! ✓              ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Run everything with one command:"
echo ""
echo -e "  ${BOLD}${CYAN}./run.sh${RESET}"
echo ""
echo -e "  Then open: ${BOLD}http://localhost:5173${RESET}"
echo ""