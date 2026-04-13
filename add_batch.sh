#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# add_batch.sh  — adds Pro batch-upload capability to FDM Checker
# Run from the project root: ./add_batch.sh
# ─────────────────────────────────────────────────────────────────────────────
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"

BOLD="\033[1m"; GREEN="\033[32m"; CYAN="\033[36m"; RESET="\033[0m"
echo -e "\n${BOLD}${CYAN}Adding batch upload…${RESET}\n"

# ══════════════════════════════════════════════════════════════════════════════
# 1. BACKEND — replace main.py with version that includes /batch endpoint
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}[1/2] Patching backend/main.py…${RESET}"
cat > "$ROOT/backend/main.py" << 'EOF'
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
EOF
echo -e "${GREEN}✓ backend/main.py updated${RESET}\n"

# ══════════════════════════════════════════════════════════════════════════════
# 2. FRONTEND — replace App.jsx with tabbed single + batch UI
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}[2/2] Patching frontend/src/App.jsx…${RESET}"
cat > "$ROOT/frontend/src/App.jsx" << 'APPEOF'
import { useState, useRef, useCallback } from "react";

const API = "/api";
const MAX_BATCH = 50;

/* ── icons ────────────────────────────────────────────────────────────────── */
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
const DownloadIcon = () => <Icon d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4M7 10l5 5 5-5M12 15V3" />;
const TrashIcon    = () => <Icon d="M3 6h18M19 6l-1 14H6L5 6M10 11v6M14 11v6M9 6V4h6v2" size={16} />;
const ZapIcon      = () => <Icon d="M13 2L3 14h9l-1 8 10-12h-9l1-8z" size={16} />;

/* ── shared helpers ───────────────────────────────────────────────────────── */
function StatusBadge({ status, small }) {
  const pass = status === "PASS", err = status === "ERROR";
  const color = pass ? "var(--pass)" : err ? "#ff9800" : "var(--fail)";
  return (
    <span style={{
      display: "inline-flex", alignItems: "center", gap: 5,
      padding: small ? "3px 10px" : "7px 18px",
      borderRadius: 999, fontSize: small ? 11 : 13,
      background: `${color}18`, border: `1px solid ${color}40`,
      fontFamily: "var(--mono)", fontWeight: 700, color,
      letterSpacing: "0.06em", whiteSpace: "nowrap",
    }}>
      {pass ? <CheckIcon /> : err ? <WarnIcon /> : <XIcon />}
      {status}
    </span>
  );
}

function IssueRow({ text, type }) {
  const isIssue = type === "issue";
  return (
    <div style={{
      display: "flex", gap: 10, alignItems: "flex-start",
      padding: "9px 13px", borderRadius: 8, marginBottom: 5,
      background: isIssue ? "#ff174408" : "#ffd74008",
      border: `1px solid ${isIssue ? "#ff174430" : "#ffd74030"}`,
    }}>
      {isIssue ? <XIcon /> : <WarnIcon />}
      <span style={{ fontSize: 13, color: "var(--text)", lineHeight: 1.5 }}>{text}</span>
    </div>
  );
}

function MetricCard({ label, value, unit, sub, accent, delay = 0 }) {
  return (
    <div style={{ animation: `fade-up 0.45s ${delay}ms ease both` }}>
      <div style={{
        background: "var(--surface)", border: "1px solid var(--border)",
        borderRadius: 12, padding: "18px 20px", position: "relative", overflow: "hidden",
      }}>
        {accent && <div style={{ position: "absolute", top: 0, left: 0, right: 0, height: 2, background: `linear-gradient(90deg,transparent,${accent},transparent)` }} />}
        <div style={{ color: "var(--text-muted)", fontSize: 10, fontFamily: "var(--mono)", letterSpacing: "0.1em", textTransform: "uppercase", marginBottom: 7 }}>{label}</div>
        <div style={{ fontSize: 26, fontWeight: 600, fontFamily: "var(--mono)", color: accent || "var(--text)", lineHeight: 1 }}>
          {value ?? "—"}{unit && <span style={{ fontSize: 13, marginLeft: 3, color: "var(--text-muted)" }}>{unit}</span>}
        </div>
        {sub && <div style={{ color: "var(--text-muted)", fontSize: 12, marginTop: 5 }}>{sub}</div>}
      </div>
    </div>
  );
}

/* ── drop zone (reused in both modes) ────────────────────────────────────── */
function DropZone({ onFiles, files, multi }) {
  const ref = useRef();
  const [drag, setDrag] = useState(false);
  const handle = useCallback((e) => {
    e.preventDefault(); setDrag(false);
    const arr = Array.from(e.dataTransfer.files);
    if (arr.length) onFiles(arr);
  }, [onFiles]);

  const label = multi
    ? files.length ? `${files.length} file${files.length > 1 ? "s" : ""} selected — drop more or click to replace`
      : "Drop up to 50 mesh files here"
    : files.length ? files[0].name : "Drop your mesh here";

  const sub = multi
    ? files.length
      ? files.slice(0, 3).map(f => f.name).join(", ") + (files.length > 3 ? ` +${files.length - 3} more` : "")
      : ".stl · .obj · .ply · .glb · .gltf — max 50 files, 50 MB each"
    : files.length
      ? `${(files[0].size / 1024).toFixed(1)} KB — click or drop to replace`
      : ".stl · .obj · .ply · .glb · .gltf — up to 50 MB";

  return (
    <div
      onClick={() => ref.current.click()}
      onDragOver={e => { e.preventDefault(); setDrag(true); }}
      onDragLeave={() => setDrag(false)}
      onDrop={handle}
      style={{
        border: `2px dashed ${drag ? "var(--accent)" : "var(--border)"}`,
        borderRadius: 14, padding: "40px 28px", textAlign: "center",
        cursor: "pointer", transition: "all 0.2s",
        background: drag ? "var(--accent-dim)" : "var(--surface)",
        position: "relative", overflow: "hidden",
      }}
    >
      <input ref={ref} type="file" accept=".stl,.obj,.ply,.glb,.gltf"
        multiple={multi} style={{ display: "none" }}
        onChange={e => { const arr = Array.from(e.target.files); if (arr.length) onFiles(arr); }} />
      {["tl","tr","bl","br"].map(c => (
        <div key={c} style={{
          position: "absolute", width: 14, height: 14,
          [c.includes("t")?"top":"bottom"]: 10, [c.includes("l")?"left":"right"]: 10,
          borderTop: c.includes("t") ? "2px solid var(--accent)" : "none",
          borderBottom: c.includes("b") ? "2px solid var(--accent)" : "none",
          borderLeft: c.includes("l") ? "2px solid var(--accent)" : "none",
          borderRight: c.includes("r") ? "2px solid var(--accent)" : "none",
          opacity: 0.45,
        }} />
      ))}
      <div style={{ color: "var(--accent)", marginBottom: 10, display: "flex", justifyContent: "center" }}><UploadIcon /></div>
      <div style={{ fontWeight: 500, marginBottom: 5, fontSize: 14, fontFamily: files.length ? "var(--mono)" : "inherit", color: files.length ? "var(--accent)" : "var(--text)" }}>{label}</div>
      <div style={{ color: "var(--text-muted)", fontSize: 12, fontFamily: "var(--mono)" }}>{sub}</div>
    </div>
  );
}

function Spinner({ label = "ANALYZING GEOMETRY" }) {
  return (
    <div style={{ textAlign: "center", padding: "40px 0" }}>
      <div style={{ width: 44, height: 44, border: "2px solid var(--border)", borderTop: "2px solid var(--accent)", borderRadius: "50%", animation: "spin-slow 0.9s linear infinite", margin: "0 auto 14px" }} />
      <div style={{ fontFamily: "var(--mono)", fontSize: 11, color: "var(--accent)", letterSpacing: "0.1em" }}>{label}</div>
    </div>
  );
}

/* ══════════════════════════════════════════════════════════════════════════ */
/* SINGLE MODE                                                                */
/* ══════════════════════════════════════════════════════════════════════════ */
function SingleMode() {
  const [files, setFiles] = useState([]);
  const [result, setResult] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);

  const analyze = async () => {
    if (!files.length) return;
    setLoading(true); setResult(null); setError(null);
    try {
      const form = new FormData();
      form.append("file", files[0]);
      const res = await fetch(`${API}/analyze`, { method: "POST", body: form });
      const json = await res.json();
      if (!res.ok) throw new Error(json.detail || "Server error");
      setResult(json);
    } catch (e) { setError(e.message); }
    finally { setLoading(false); }
  };

  const downloadJSON = () => {
    const blob = new Blob([JSON.stringify(result, null, 2)], { type: "application/json" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = `fdm-report-${result.filename.replace(/\.[^.]+$/, "")}.json`;
    a.click();
  };

  return (
    <>
      <DropZone onFiles={setFiles} files={files} multi={false} />
      <button onClick={analyze} disabled={!files.length || loading} style={{
        width: "100%", marginTop: 14, padding: "13px 0", borderRadius: 10,
        border: "none", cursor: files.length && !loading ? "pointer" : "not-allowed",
        fontFamily: "var(--mono)", fontWeight: 700, fontSize: 13, letterSpacing: "0.1em",
        background: files.length && !loading ? "linear-gradient(135deg,var(--accent),#0097a7)" : "var(--surface-2)",
        color: files.length && !loading ? "#000" : "var(--text-muted)", transition: "all 0.2s",
      }}>
        {loading ? "ANALYZING…" : "ANALYZE MESH"}
      </button>

      {error && <div style={{ marginTop: 14, padding: "11px 15px", borderRadius: 8, background: "#ff174410", border: "1px solid #ff174440", color: "var(--fail)", fontFamily: "var(--mono)", fontSize: 13 }}>✗ {error}</div>}
      {loading && <Spinner />}

      {result && !loading && (() => {
        const { status, mesh_info: m, wall_thickness: w, overhangs: o, issues, warnings } = result;
        return (
          <div style={{ marginTop: 28 }}>
            <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 20, flexWrap: "wrap", gap: 10 }}>
              <div>
                <div style={{ fontFamily: "var(--mono)", fontSize: 10, color: "var(--text-muted)", letterSpacing: "0.1em", marginBottom: 5 }}>ANALYSIS RESULT</div>
                <StatusBadge status={status} />
              </div>
              <button onClick={downloadJSON} style={{ display: "flex", alignItems: "center", gap: 7, padding: "7px 14px", borderRadius: 8, background: "var(--surface-2)", border: "1px solid var(--border)", color: "var(--text-muted)", cursor: "pointer", fontSize: 11, fontFamily: "var(--mono)", transition: "all 0.15s" }}
                onMouseEnter={e => e.currentTarget.style.borderColor = "var(--accent)"}
                onMouseLeave={e => e.currentTarget.style.borderColor = "var(--border)"}>
                <DownloadIcon /> EXPORT JSON
              </button>
            </div>
            {issues.map((t, i) => <IssueRow key={i} text={t} type="issue" />)}
            {warnings.map((t, i) => <IssueRow key={i} text={t} type="warning" />)}
            <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill,minmax(160px,1fr))", gap: 10, margin: "18px 0" }}>
              <MetricCard delay={0}   label="Min Wall" accent={w.min_wall_thickness_mm < 1.2 ? "var(--fail)" : "var(--pass)"} value={w.error ? "ERR" : w.min_wall_thickness_mm} unit="mm" sub={w.error ? w.error.slice(0,40) : `mean ${w.mean_wall_thickness_mm} mm`} />
              <MetricCard delay={60}  label="Overhangs" accent={o.overhang_percentage > 30 ? "var(--warn)" : "var(--pass)"} value={o.overhang_percentage} unit="%" sub={`${o.violating_faces} / ${o.total_faces} faces`} />
              <MetricCard delay={120} label="Watertight" accent={m.is_watertight ? "var(--pass)" : "var(--fail)"} value={m.is_watertight ? "YES" : "NO"} sub="mesh integrity" />
              <MetricCard delay={180} label="Volume" accent="var(--accent)" value={m.volume_cm3 ?? "—"} unit="cm³" sub={`${(m.vertices/1000).toFixed(1)}k verts · ${(m.faces/1000).toFixed(1)}k faces`} />
            </div>
            <div style={{ background: "var(--surface)", border: "1px solid var(--border)", borderRadius: 12, padding: "14px 20px" }}>
              <div style={{ display: "flex", alignItems: "center", gap: 7, marginBottom: 10, color: "var(--text-muted)", fontSize: 10, fontFamily: "var(--mono)", letterSpacing: "0.1em" }}><CubeIcon />BOUNDING BOX</div>
              <div style={{ display: "flex", gap: 20, fontFamily: "var(--mono)", fontSize: 13 }}>
                {["x","y","z"].map(ax => (
                  <div key={ax}><span style={{ color: "var(--text-muted)", marginRight: 5 }}>{ax.toUpperCase()}</span><span style={{ color: "var(--accent)" }}>{m.bounding_box_mm[ax]}</span><span style={{ color: "var(--text-muted)", marginLeft: 2 }}>mm</span></div>
                ))}
              </div>
            </div>
          </div>
        );
      })()}
    </>
  );
}

/* ══════════════════════════════════════════════════════════════════════════ */
/* BATCH MODE (Pro)                                                           */
/* ══════════════════════════════════════════════════════════════════════════ */
const STATUS_ORDER = { FAIL: 0, ERROR: 1, PASS: 2 };

function BatchMode() {
  const [files, setFiles] = useState([]);
  const [results, setResults] = useState(null);
  const [loading, setLoading] = useState(false);
  const [progress, setProgress] = useState({ done: 0, total: 0 });
  const [error, setError] = useState(null);
  const [expandedIdx, setExpandedIdx] = useState(null);
  const [filter, setFilter] = useState("ALL");

  const addFiles = (incoming) => {
    setFiles(prev => {
      const existing = new Set(prev.map(f => f.name + f.size));
      const fresh = incoming.filter(f => !existing.has(f.name + f.size));
      const merged = [...prev, ...fresh].slice(0, MAX_BATCH);
      return merged;
    });
    setResults(null);
  };

  const removeFile = (idx) => {
    setFiles(prev => prev.filter((_, i) => i !== idx));
    setResults(null);
  };

  // Send in chunks of 10 to show live progress
  const analyze = async () => {
    if (!files.length) return;
    setLoading(true); setResults(null); setError(null);
    setProgress({ done: 0, total: files.length });

    const CHUNK = 10;
    const allResults = [];

    try {
      for (let i = 0; i < files.length; i += CHUNK) {
        const chunk = files.slice(i, i + CHUNK);
        const form = new FormData();
        chunk.forEach(f => form.append("files", f));
        const res = await fetch(`${API}/batch`, { method: "POST", body: form });
        const json = await res.json();
        if (!res.ok) throw new Error(json.detail || "Server error");
        allResults.push(...json.results);
        setProgress({ done: Math.min(i + CHUNK, files.length), total: files.length });
      }

      const passed  = allResults.filter(r => r.status === "PASS").length;
      const failed  = allResults.filter(r => r.status === "FAIL").length;
      const errored = allResults.filter(r => r.status === "ERROR").length;

      setResults({
        total: allResults.length,
        passed, failed, errored,
        results: allResults.sort((a, b) =>
          (STATUS_ORDER[a.status] ?? 9) - (STATUS_ORDER[b.status] ?? 9)
        ),
      });
    } catch (e) { setError(e.message); }
    finally { setLoading(false); }
  };

  const downloadCSV = () => {
    if (!results) return;
    const cols = ["filename","status","min_wall_mm","mean_wall_mm","overhang_%","watertight","volume_cm3","issues","warnings"];
    const rows = results.results.map(r => [
      r.filename,
      r.status,
      r.wall_thickness?.min_wall_thickness_mm ?? "",
      r.wall_thickness?.mean_wall_thickness_mm ?? "",
      r.overhangs?.overhang_percentage ?? "",
      r.mesh_info?.is_watertight ?? "",
      r.mesh_info?.volume_cm3 ?? "",
      (r.issues || []).join("; "),
      (r.warnings || []).join("; "),
    ]);
    const csv = [cols, ...rows].map(r => r.map(v => `"${String(v).replace(/"/g,'""')}"`).join(",")).join("\n");
    const a = document.createElement("a");
    a.href = URL.createObjectURL(new Blob([csv], { type: "text/csv" }));
    a.download = `fdm-batch-report-${Date.now()}.csv`;
    a.click();
  };

  const downloadJSON = () => {
    if (!results) return;
    const a = document.createElement("a");
    a.href = URL.createObjectURL(new Blob([JSON.stringify(results, null, 2)], { type: "application/json" }));
    a.download = `fdm-batch-report-${Date.now()}.json`;
    a.click();
  };

  const filtered = results
    ? (filter === "ALL" ? results.results : results.results.filter(r => r.status === filter))
    : [];

  return (
    <>
      {/* Pro badge */}
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 16 }}>
        <div style={{ display: "inline-flex", alignItems: "center", gap: 6, padding: "4px 12px", borderRadius: 999, background: "#ffd74018", border: "1px solid #ffd74040", fontFamily: "var(--mono)", fontSize: 11, color: "var(--warn)", letterSpacing: "0.08em" }}>
          <ZapIcon /> PRO — UP TO 50 FILES
        </div>
        <span style={{ color: "var(--text-muted)", fontSize: 12 }}>All files processed in parallel</span>
      </div>

      <DropZone onFiles={addFiles} files={files} multi={true} />

      {/* File queue */}
      {files.length > 0 && !results && (
        <div style={{ marginTop: 14, background: "var(--surface)", border: "1px solid var(--border)", borderRadius: 12, overflow: "hidden" }}>
          <div style={{ padding: "10px 16px", borderBottom: "1px solid var(--border)", display: "flex", justifyContent: "space-between", alignItems: "center" }}>
            <span style={{ fontFamily: "var(--mono)", fontSize: 11, color: "var(--text-muted)", letterSpacing: "0.08em" }}>QUEUE — {files.length}/{MAX_BATCH} FILES</span>
            <button onClick={() => setFiles([])} style={{ background: "none", border: "none", color: "var(--text-muted)", cursor: "pointer", fontSize: 11, fontFamily: "var(--mono)" }}>CLEAR ALL</button>
          </div>
          <div style={{ maxHeight: 220, overflowY: "auto" }}>
            {files.map((f, i) => (
              <div key={i} style={{ display: "flex", alignItems: "center", justifyContent: "space-between", padding: "8px 16px", borderBottom: i < files.length - 1 ? "1px solid var(--border)" : "none" }}>
                <span style={{ fontFamily: "var(--mono)", fontSize: 12, color: "var(--text)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", maxWidth: "80%" }}>{f.name}</span>
                <div style={{ display: "flex", alignItems: "center", gap: 12, flexShrink: 0 }}>
                  <span style={{ color: "var(--text-muted)", fontSize: 11 }}>{(f.size / 1024).toFixed(0)} KB</span>
                  <button onClick={() => removeFile(i)} style={{ background: "none", border: "none", color: "var(--text-muted)", cursor: "pointer", display: "flex", padding: 2 }}><TrashIcon /></button>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      <button onClick={analyze} disabled={!files.length || loading} style={{
        width: "100%", marginTop: 14, padding: "13px 0", borderRadius: 10,
        border: "none", cursor: files.length && !loading ? "pointer" : "not-allowed",
        fontFamily: "var(--mono)", fontWeight: 700, fontSize: 13, letterSpacing: "0.1em",
        background: files.length && !loading ? "linear-gradient(135deg,var(--accent),#0097a7)" : "var(--surface-2)",
        color: files.length && !loading ? "#000" : "var(--text-muted)", transition: "all 0.2s",
      }}>
        {loading ? `ANALYZING ${progress.done}/${progress.total}…` : `ANALYZE ${files.length || ""} FILES`}
      </button>

      {/* Progress bar */}
      {loading && (
        <div style={{ marginTop: 10, height: 3, background: "var(--border)", borderRadius: 2, overflow: "hidden" }}>
          <div style={{ height: "100%", width: `${progress.total ? (progress.done / progress.total) * 100 : 0}%`, background: "var(--accent)", transition: "width 0.4s ease", borderRadius: 2 }} />
        </div>
      )}

      {error && <div style={{ marginTop: 14, padding: "11px 15px", borderRadius: 8, background: "#ff174410", border: "1px solid #ff174440", color: "var(--fail)", fontFamily: "var(--mono)", fontSize: 13 }}>✗ {error}</div>}

      {/* Results */}
      {results && !loading && (
        <div style={{ marginTop: 28, animation: "fade-up 0.4s ease both" }}>
          {/* Summary row */}
          <div style={{ display: "grid", gridTemplateColumns: "repeat(3,1fr)", gap: 10, marginBottom: 20 }}>
            {[
              { label: "PASSED", value: results.passed, color: "var(--pass)" },
              { label: "FAILED", value: results.failed, color: "var(--fail)" },
              { label: "ERRORS", value: results.errored, color: "var(--warn)" },
            ].map(({ label, value, color }) => (
              <div key={label} style={{ background: "var(--surface)", border: "1px solid var(--border)", borderRadius: 12, padding: "16px 20px", textAlign: "center", position: "relative", overflow: "hidden" }}>
                <div style={{ position: "absolute", top: 0, left: 0, right: 0, height: 2, background: `linear-gradient(90deg,transparent,${color},transparent)` }} />
                <div style={{ fontFamily: "var(--mono)", fontSize: 28, fontWeight: 700, color }}>{value}</div>
                <div style={{ fontFamily: "var(--mono)", fontSize: 10, color: "var(--text-muted)", letterSpacing: "0.1em", marginTop: 4 }}>{label}</div>
              </div>
            ))}
          </div>

          {/* Export + filter bar */}
          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 12, gap: 10, flexWrap: "wrap" }}>
            <div style={{ display: "flex", gap: 6 }}>
              {["ALL","PASS","FAIL","ERROR"].map(f => (
                <button key={f} onClick={() => setFilter(f)} style={{
                  padding: "5px 12px", borderRadius: 6, border: "1px solid var(--border)",
                  background: filter === f ? "var(--accent)" : "var(--surface)",
                  color: filter === f ? "#000" : "var(--text-muted)",
                  fontFamily: "var(--mono)", fontSize: 11, cursor: "pointer", transition: "all 0.15s",
                }}>{f}</button>
              ))}
            </div>
            <div style={{ display: "flex", gap: 8 }}>
              <button onClick={downloadCSV} style={{ display: "flex", alignItems: "center", gap: 6, padding: "6px 12px", borderRadius: 8, background: "var(--surface-2)", border: "1px solid var(--border)", color: "var(--text-muted)", cursor: "pointer", fontSize: 11, fontFamily: "var(--mono)" }}
                onMouseEnter={e => e.currentTarget.style.borderColor = "var(--accent)"}
                onMouseLeave={e => e.currentTarget.style.borderColor = "var(--border)"}>
                <DownloadIcon /> CSV
              </button>
              <button onClick={downloadJSON} style={{ display: "flex", alignItems: "center", gap: 6, padding: "6px 12px", borderRadius: 8, background: "var(--surface-2)", border: "1px solid var(--border)", color: "var(--text-muted)", cursor: "pointer", fontSize: 11, fontFamily: "var(--mono)" }}
                onMouseEnter={e => e.currentTarget.style.borderColor = "var(--accent)"}
                onMouseLeave={e => e.currentTarget.style.borderColor = "var(--border)"}>
                <DownloadIcon /> JSON
              </button>
            </div>
          </div>

          {/* Results table */}
          <div style={{ background: "var(--surface)", border: "1px solid var(--border)", borderRadius: 12, overflow: "hidden" }}>
            {/* Header */}
            <div style={{ display: "grid", gridTemplateColumns: "1fr 90px 90px 90px 90px 36px", gap: 0, padding: "9px 16px", borderBottom: "1px solid var(--border)", fontFamily: "var(--mono)", fontSize: 10, color: "var(--text-muted)", letterSpacing: "0.08em" }}>
              <span>FILE</span><span style={{textAlign:"center"}}>STATUS</span><span style={{textAlign:"center"}}>WALL</span><span style={{textAlign:"center"}}>OVERHANG</span><span style={{textAlign:"center"}}>WATERTIGHT</span><span />
            </div>
            {filtered.length === 0 && (
              <div style={{ padding: "24px", textAlign: "center", color: "var(--text-muted)", fontSize: 13 }}>No results match this filter.</div>
            )}
            {filtered.map((r, i) => {
              const isOpen = expandedIdx === i;
              const wall = r.wall_thickness;
              const over = r.overhangs;
              const mesh = r.mesh_info;
              return (
                <div key={i}>
                  <div
                    onClick={() => setExpandedIdx(isOpen ? null : i)}
                    style={{ display: "grid", gridTemplateColumns: "1fr 90px 90px 90px 90px 36px", gap: 0, padding: "11px 16px", borderBottom: "1px solid var(--border)", cursor: "pointer", transition: "background 0.15s", alignItems: "center", background: isOpen ? "var(--surface-2)" : "transparent" }}
                    onMouseEnter={e => !isOpen && (e.currentTarget.style.background = "#ffffff08")}
                    onMouseLeave={e => !isOpen && (e.currentTarget.style.background = "transparent")}
                  >
                    <span style={{ fontFamily: "var(--mono)", fontSize: 12, color: "var(--text)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{r.filename}</span>
                    <span style={{ textAlign: "center" }}><StatusBadge status={r.status} small /></span>
                    <span style={{ textAlign: "center", fontFamily: "var(--mono)", fontSize: 12, color: wall?.min_wall_thickness_mm < 1.2 ? "var(--fail)" : "var(--pass)" }}>
                      {wall?.min_wall_thickness_mm != null ? `${wall.min_wall_thickness_mm}mm` : "—"}
                    </span>
                    <span style={{ textAlign: "center", fontFamily: "var(--mono)", fontSize: 12, color: over?.overhang_percentage > 30 ? "var(--warn)" : "var(--text-muted)" }}>
                      {over?.overhang_percentage != null ? `${over.overhang_percentage}%` : "—"}
                    </span>
                    <span style={{ textAlign: "center", fontFamily: "var(--mono)", fontSize: 12, color: mesh?.is_watertight ? "var(--pass)" : "var(--fail)" }}>
                      {mesh?.is_watertight != null ? (mesh.is_watertight ? "YES" : "NO") : "—"}
                    </span>
                    <span style={{ textAlign: "center", color: "var(--text-muted)", fontSize: 16, lineHeight: 1 }}>{isOpen ? "▲" : "▼"}</span>
                  </div>

                  {/* Expanded detail row */}
                  {isOpen && (
                    <div style={{ padding: "14px 16px 16px", background: "var(--surface-2)", borderBottom: "1px solid var(--border)" }}>
                      {r.status === "ERROR"
                        ? <div style={{ color: "var(--warn)", fontFamily: "var(--mono)", fontSize: 12 }}>✗ {r.error}</div>
                        : <>
                          {(r.issues || []).map((t, j) => <IssueRow key={j} text={t} type="issue" />)}
                          {(r.warnings || []).map((t, j) => <IssueRow key={j} text={t} type="warning" />)}
                          {r.issues?.length === 0 && r.warnings?.length === 0 &&
                            <div style={{ color: "var(--pass)", fontFamily: "var(--mono)", fontSize: 12 }}>✓ No issues detected</div>}
                          {mesh && (
                            <div style={{ display: "flex", gap: 20, marginTop: 10, fontFamily: "var(--mono)", fontSize: 12, color: "var(--text-muted)" }}>
                              <span>Vol: <span style={{ color: "var(--text)" }}>{mesh.volume_cm3} cm³</span></span>
                              <span>Verts: <span style={{ color: "var(--text)" }}>{(mesh.vertices/1000).toFixed(1)}k</span></span>
                              <span>BBox: <span style={{ color: "var(--text)" }}>{mesh.bounding_box_mm?.x}×{mesh.bounding_box_mm?.y}×{mesh.bounding_box_mm?.z} mm</span></span>
                            </div>
                          )}
                        </>
                      }
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        </div>
      )}
    </>
  );
}

/* ══════════════════════════════════════════════════════════════════════════ */
/* ROOT APP                                                                   */
/* ══════════════════════════════════════════════════════════════════════════ */
export default function App() {
  const [tab, setTab] = useState("single");

  return (
    <div style={{ minHeight: "100vh", background: "var(--bg)", paddingBottom: 80 }}>
      {/* Nav */}
      <header style={{ borderBottom: "1px solid var(--border)", padding: "0 32px", display: "flex", alignItems: "center", justifyContent: "space-between", height: 56, background: "var(--surface)", position: "sticky", top: 0, zIndex: 10 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
          <LayersIcon />
          <span style={{ fontFamily: "var(--mono)", fontWeight: 700, fontSize: 13, letterSpacing: "0.08em", color: "var(--accent)" }}>FDM CHECKER</span>
        </div>
        <div style={{ fontFamily: "var(--mono)", fontSize: 11, color: "var(--text-muted)" }}>v1.1 · localhost</div>
      </header>

      <div style={{ padding: "48px 32px 0", maxWidth: 720, margin: "0 auto" }}>
        {/* Hero */}
        <div style={{ marginBottom: 8, fontFamily: "var(--mono)", fontSize: 11, color: "var(--accent)", letterSpacing: "0.15em" }}>FDM PRINTABILITY ANALYSIS</div>
        <h1 style={{ fontSize: "clamp(26px,5vw,42px)", fontWeight: 300, lineHeight: 1.1, marginBottom: 10, color: "var(--text)" }}>
          Will your model<br />
          <em style={{ fontStyle: "italic", color: "var(--accent)" }}>actually print?</em>
        </h1>
        <p style={{ color: "var(--text-muted)", fontSize: 15, lineHeight: 1.6, marginBottom: 32, maxWidth: 520 }}>
          Check wall thickness, overhangs, and mesh integrity — before you waste filament.
        </p>

        {/* Mode tabs */}
        <div style={{ display: "flex", gap: 4, marginBottom: 28, background: "var(--surface)", border: "1px solid var(--border)", borderRadius: 10, padding: 4, width: "fit-content" }}>
          {[
            { id: "single", label: "Single File" },
            { id: "batch",  label: "⚡ Batch (Pro)" },
          ].map(({ id, label }) => (
            <button key={id} onClick={() => setTab(id)} style={{
              padding: "7px 20px", borderRadius: 7, border: "none", cursor: "pointer",
              fontFamily: "var(--mono)", fontSize: 12, fontWeight: 700, letterSpacing: "0.05em",
              background: tab === id ? (id === "batch" ? "var(--accent)" : "var(--surface-2)") : "transparent",
              color: tab === id ? (id === "batch" ? "#000" : "var(--text)") : "var(--text-muted)",
              transition: "all 0.15s",
            }}>{label}</button>
          ))}
        </div>

        {tab === "single" ? <SingleMode /> : <BatchMode />}
      </div>
    </div>
  );
}
APPEOF

echo -e "${GREEN}✓ frontend/src/App.jsx updated${RESET}\n"

echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║        Batch mode added! ✓               ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════╝${RESET}"
echo ""
echo "  Restart the servers to pick up the changes:"
echo ""
echo "  ./run.sh"
echo ""
