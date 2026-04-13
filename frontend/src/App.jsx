import { useState, useRef, useCallback } from "react";
import MeshViewer from "./MeshViewer.jsx";

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

/* ── drop zone ────────────────────────────────────────────────────────────── */
function DropZone({ onFiles, files, multi }) {
  const ref = useRef();
  const [drag, setDrag] = useState(false);
  const handle = useCallback((e) => {
    e.preventDefault(); setDrag(false);
    const arr = Array.from(e.dataTransfer.files);
    if (arr.length) onFiles(arr);
  }, [onFiles]);

  const label = multi
    ? files.length ? `${files.length} file${files.length > 1 ? "s" : ""} queued`
      : "Drop up to 50 mesh files here"
    : files.length ? files[0].name : "Drop your mesh here";

  const sub = multi
    ? files.length
      ? files.slice(0, 3).map(f => f.name).join(", ") + (files.length > 3 ? ` +${files.length - 3} more` : "")
      : ".stl · .obj · .ply · .glb · .gltf — max 50 files"
    : files.length
      ? `${(files[0].size / 1024).toFixed(1)} KB · click or drop to replace`
      : ".stl · .obj · .ply · .glb · .gltf — up to 50 MB";

  return (
    <div
      onClick={() => ref.current.click()}
      onDragOver={e => { e.preventDefault(); setDrag(true); }}
      onDragLeave={() => setDrag(false)}
      onDrop={handle}
      style={{
        border: `2px dashed ${drag ? "var(--accent)" : "var(--border)"}`,
        borderRadius: 12, padding: "28px 24px", textAlign: "center",
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
          position: "absolute", width: 12, height: 12,
          [c.includes("t")?"top":"bottom"]: 8, [c.includes("l")?"left":"right"]: 8,
          borderTop: c.includes("t") ? "2px solid var(--accent)" : "none",
          borderBottom: c.includes("b") ? "2px solid var(--accent)" : "none",
          borderLeft: c.includes("l") ? "2px solid var(--accent)" : "none",
          borderRight: c.includes("r") ? "2px solid var(--accent)" : "none",
          opacity: 0.4,
        }} />
      ))}
      <div style={{ color: "var(--accent)", marginBottom: 8, display: "flex", justifyContent: "center" }}><UploadIcon /></div>
      <div style={{ fontWeight: 500, marginBottom: 4, fontSize: 14,
        fontFamily: files.length ? "var(--mono)" : "inherit",
        color: files.length ? "var(--accent)" : "var(--text)" }}>{label}</div>
      <div style={{ color: "var(--text-muted)", fontSize: 11, fontFamily: "var(--mono)" }}>{sub}</div>
    </div>
  );
}

function Spinner({ label = "ANALYZING GEOMETRY" }) {
  return (
    <div style={{ textAlign: "center", padding: "32px 0" }}>
      <div style={{ width: 40, height: 40, border: "2px solid var(--border)", borderTop: "2px solid var(--accent)", borderRadius: "50%", animation: "spin-slow 0.9s linear infinite", margin: "0 auto 12px" }} />
      <div style={{ fontFamily: "var(--mono)", fontSize: 11, color: "var(--accent)", letterSpacing: "0.1em" }}>{label}</div>
    </div>
  );
}

/* ══════════════════════════════════════════════════════════════════════════ */
/* SINGLE MODE — with 3D viewer                                               */
/* ══════════════════════════════════════════════════════════════════════════ */
function SingleMode() {
  const [files,   setFiles]   = useState([]);
  const [result,  setResult]  = useState(null);
  const [loading, setLoading] = useState(false);
  const [error,   setError]   = useState(null);

  const file = files[0] ?? null;

  const analyze = async () => {
    if (!file) return;
    setLoading(true); setResult(null); setError(null);
    try {
      const form = new FormData();
      form.append("file", file);
      const res  = await fetch(`${API}/analyze`, { method: "POST", body: form });
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
    /* Two-column layout once a file is loaded */
    <div style={{
      display: "grid",
      gridTemplateColumns: file ? "1fr 1fr" : "1fr",
      gap: 20,
      alignItems: "start",
    }}>

      {/* ── LEFT / TOP: controls + results ── */}
      <div>
        <DropZone onFiles={f => { setFiles(f); setResult(null); setError(null); }}
          files={files} multi={false} />

        <button onClick={analyze} disabled={!file || loading} style={{
          width: "100%", marginTop: 12, padding: "12px 0", borderRadius: 10,
          border: "none", cursor: file && !loading ? "pointer" : "not-allowed",
          fontFamily: "var(--mono)", fontWeight: 700, fontSize: 13, letterSpacing: "0.1em",
          background: file && !loading ? "linear-gradient(135deg,var(--accent),#0097a7)" : "var(--surface-2)",
          color: file && !loading ? "#000" : "var(--text-muted)", transition: "all 0.2s",
        }}>
          {loading ? "ANALYZING…" : "ANALYZE MESH"}
        </button>

        {error && (
          <div style={{ marginTop: 12, padding: "10px 14px", borderRadius: 8,
            background: "#ff174410", border: "1px solid #ff174440",
            color: "var(--fail)", fontFamily: "var(--mono)", fontSize: 12 }}>
            ✗ {error}
          </div>
        )}

        {loading && <Spinner />}

        {result && !loading && (() => {
          const { status, mesh_info: m, wall_thickness: w, overhangs: o, issues, warnings } = result;
          return (
            <div style={{ marginTop: 20 }}>
              {/* header */}
              <div style={{ display: "flex", alignItems: "center",
                justifyContent: "space-between", marginBottom: 14,
                flexWrap: "wrap", gap: 8 }}>
                <div>
                  <div style={{ fontFamily: "var(--mono)", fontSize: 10,
                    color: "var(--text-muted)", letterSpacing: "0.1em", marginBottom: 4 }}>
                    ANALYSIS RESULT
                  </div>
                  <StatusBadge status={status} />
                </div>
                <button onClick={downloadJSON} style={{
                  display: "flex", alignItems: "center", gap: 6,
                  padding: "6px 12px", borderRadius: 8,
                  background: "var(--surface-2)", border: "1px solid var(--border)",
                  color: "var(--text-muted)", cursor: "pointer",
                  fontSize: 11, fontFamily: "var(--mono)", transition: "all 0.15s" }}
                  onMouseEnter={e => e.currentTarget.style.borderColor = "var(--accent)"}
                  onMouseLeave={e => e.currentTarget.style.borderColor = "var(--border)"}>
                  <DownloadIcon /> JSON
                </button>
              </div>

              {issues.map((t, i) => <IssueRow key={i} text={t} type="issue" />)}
              {warnings.map((t, i) => <IssueRow key={i} text={t} type="warning" />)}

              <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr",
                gap: 8, margin: "14px 0" }}>
                <MetricCard delay={0} label="Min Wall"
                  accent={w.min_wall_thickness_mm < 1.2 ? "var(--fail)" : "var(--pass)"}
                  value={w.error ? "ERR" : w.min_wall_thickness_mm} unit="mm"
                  sub={w.error ? w.error.slice(0,36) : `mean ${w.mean_wall_thickness_mm} mm`} />
                <MetricCard delay={60} label="Overhangs"
                  accent={o.overhang_percentage > 30 ? "var(--warn)" : "var(--pass)"}
                  value={o.overhang_percentage} unit="%"
                  sub={`${o.violating_faces} / ${o.total_faces} faces`} />
                <MetricCard delay={120} label="Watertight"
                  accent={m.is_watertight ? "var(--pass)" : "var(--fail)"}
                  value={m.is_watertight ? "YES" : "NO"} sub="mesh integrity" />
                <MetricCard delay={180} label="Volume"
                  accent="var(--accent)" value={m.volume_cm3 ?? "—"} unit="cm³"
                  sub={`${(m.vertices/1000).toFixed(1)}k verts`} />
              </div>

              {/* bounding box */}
              <div style={{ background: "var(--surface)", border: "1px solid var(--border)",
                borderRadius: 10, padding: "12px 16px" }}>
                <div style={{ display: "flex", alignItems: "center", gap: 6,
                  marginBottom: 8, color: "var(--text-muted)",
                  fontSize: 10, fontFamily: "var(--mono)", letterSpacing: "0.1em" }}>
                  <CubeIcon />BOUNDING BOX
                </div>
                <div style={{ display: "flex", gap: 16, fontFamily: "var(--mono)", fontSize: 12 }}>
                  {["x","y","z"].map(ax => (
                    <div key={ax}>
                      <span style={{ color: "var(--text-muted)", marginRight: 4 }}>{ax.toUpperCase()}</span>
                      <span style={{ color: "var(--accent)" }}>{m.bounding_box_mm[ax]}</span>
                      <span style={{ color: "var(--text-muted)", marginLeft: 2 }}>mm</span>
                    </div>
                  ))}
                </div>
              </div>
            </div>
          );
        })()}
      </div>

      {/* ── RIGHT: 3D viewer (only when file selected) ── */}
      {file && (
        <div style={{ position: "sticky", top: 80 }}>
          <div style={{ fontFamily: "var(--mono)", fontSize: 10,
            color: "var(--text-muted)", letterSpacing: "0.1em",
            marginBottom: 8 }}>
            3D PREVIEW
          </div>
          <MeshViewer
            file={file}
            status={result?.status ?? null}
          />
          {!result && !loading && (
            <div style={{ marginTop: 8, fontFamily: "var(--mono)", fontSize: 11,
              color: "var(--text-muted)", textAlign: "center" }}>
              Preview ready — click Analyze to check printability
            </div>
          )}
        </div>
      )}
    </div>
  );
}

/* ══════════════════════════════════════════════════════════════════════════ */
/* BATCH MODE (Pro) — WITH 3D PREVIEW                                         */
/* ══════════════════════════════════════════════════════════════════════════ */
const STATUS_ORDER = { FAIL: 0, ERROR: 1, PASS: 2 };

function BatchMode() {
  const [files,      setFiles]      = useState([]);
  const [results,    setResults]    = useState(null);
  const [loading,    setLoading]    = useState(false);
  const [progress,   setProgress]   = useState({ done: 0, total: 0 });
  const [error,      setError]      = useState(null);
  const [expandedIdx,setExpandedIdx]= useState(null);
  const [filter,     setFilter]     = useState("ALL");
  const [previewFile,setPreviewFile] = useState(null);
  const [previewStatus,setPreviewStatus] = useState(null);

  const addFiles = (incoming) => {
    setFiles(prev => {
      const existing = new Set(prev.map(f => f.name + f.size));
      const fresh = incoming.filter(f => !existing.has(f.name + f.size));
      return [...prev, ...fresh].slice(0, MAX_BATCH);
    });
    setResults(null);
  };

  const removeFile = (idx) => {
    setFiles(prev => prev.filter((_, i) => i !== idx));
    setResults(null);
  };

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
        const res  = await fetch(`${API}/batch`, { method: "POST", body: form });
        const json = await res.json();
        if (!res.ok) throw new Error(json.detail || "Server error");
        allResults.push(...json.results);
        setProgress({ done: Math.min(i + CHUNK, files.length), total: files.length });
      }
      const passed  = allResults.filter(r => r.status === "PASS").length;
      const failed  = allResults.filter(r => r.status === "FAIL").length;
      const errored = allResults.filter(r => r.status === "ERROR").length;
      setResults({
        total: allResults.length, passed, failed, errored,
        results: allResults.sort((a, b) =>
          (STATUS_ORDER[a.status] ?? 9) - (STATUS_ORDER[b.status] ?? 9)),
      });
    } catch (e) { setError(e.message); }
    finally { setLoading(false); }
  };

  const downloadCSV = () => {
    if (!results) return;
    const cols = ["filename","status","min_wall_mm","mean_wall_mm","overhang_%","watertight","volume_cm3","issues","warnings"];
    const rows = results.results.map(r => [
      r.filename, r.status,
      r.wall_thickness?.min_wall_thickness_mm ?? "",
      r.wall_thickness?.mean_wall_thickness_mm ?? "",
      r.overhangs?.overhang_percentage ?? "",
      r.mesh_info?.is_watertight ?? "",
      r.mesh_info?.volume_cm3 ?? "",
      (r.issues||[]).join("; "),
      (r.warnings||[]).join("; "),
    ]);
    const csv = [cols,...rows].map(r=>r.map(v=>`"${String(v).replace(/"/g,'""')}"`).join(",")).join("\n");
    const a = document.createElement("a");
    a.href = URL.createObjectURL(new Blob([csv],{type:"text/csv"}));
    a.download = `fdm-batch-report-${Date.now()}.csv`;
    a.click();
  };

  const downloadJSON = () => {
    if (!results) return;
    const a = document.createElement("a");
    a.href = URL.createObjectURL(new Blob([JSON.stringify(results,null,2)],{type:"application/json"}));
    a.download = `fdm-batch-report-${Date.now()}.json`;
    a.click();
  };

  const filtered = results
    ? (filter === "ALL" ? results.results : results.results.filter(r => r.status === filter))
    : [];

  const selectRowPreview = (r, i) => {
    const f = files.find(f => f.name === r.filename) ?? null;
    setPreviewFile(f);
    setPreviewStatus(r.status);
    setExpandedIdx(expandedIdx === i ? null : i);
  };

  return (
    <div style={{ display: "grid", gridTemplateColumns: previewFile ? "1fr 340px" : "1fr", gap: 20, alignItems: "start" }}>
      <div>
        {/* pro badge */}
        <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 14 }}>
          <div style={{ display: "inline-flex", alignItems: "center", gap: 6,
            padding: "3px 10px", borderRadius: 999,
            background: "#ffd74018", border: "1px solid #ffd74040",
            fontFamily: "var(--mono)", fontSize: 11, color: "var(--warn)" }}>
            <ZapIcon /> PRO — UP TO 50 FILES
          </div>
        </div>

        <DropZone onFiles={addFiles} files={files} multi={true} />

        {/* queue */}
        {files.length > 0 && !results && (
          <div style={{ marginTop: 12, background: "var(--surface)",
            border: "1px solid var(--border)", borderRadius: 10, overflow: "hidden" }}>
            <div style={{ padding: "8px 14px", borderBottom: "1px solid var(--border)",
              display: "flex", justifyContent: "space-between", alignItems: "center" }}>
              <span style={{ fontFamily: "var(--mono)", fontSize: 10,
                color: "var(--text-muted)", letterSpacing: "0.08em" }}>
                QUEUE — {files.length}/{MAX_BATCH}
              </span>
              <button onClick={() => setFiles([])} style={{ background:"none", border:"none",
                color:"var(--text-muted)", cursor:"pointer", fontSize:11, fontFamily:"var(--mono)" }}>
                CLEAR ALL
              </button>
            </div>
            <div style={{ maxHeight: 180, overflowY: "auto" }}>
              {files.map((f, i) => (
                <div key={i} style={{ display: "flex", alignItems: "center",
                  justifyContent: "space-between", padding: "7px 14px",
                  borderBottom: i < files.length-1 ? "1px solid var(--border)" : "none",
                  cursor: "pointer", background: previewFile?.name===f.name ? "var(--surface-2)" : "transparent",
                  transition: "background 0.15s" }}
                  onClick={() => { setPreviewFile(f); setPreviewStatus(null); }}>
                  <span style={{ fontFamily:"var(--mono)", fontSize:12, color:"var(--text)",
                    overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap", maxWidth:"75%" }}>
                    {f.name}
                  </span>
                  <div style={{ display:"flex", alignItems:"center", gap:10, flexShrink:0 }}>
                    <span style={{ color:"var(--text-muted)", fontSize:11 }}>{(f.size/1024).toFixed(0)} KB</span>
                    <button onClick={e=>{e.stopPropagation();removeFile(i);}}
                      style={{ background:"none", border:"none", color:"var(--text-muted)", cursor:"pointer", display:"flex", padding:2 }}>
                      <TrashIcon />
                    </button>
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}

        <button onClick={analyze} disabled={!files.length || loading} style={{
          width:"100%", marginTop:12, padding:"12px 0", borderRadius:10,
          border:"none", cursor: files.length && !loading ? "pointer" : "not-allowed",
          fontFamily:"var(--mono)", fontWeight:700, fontSize:13, letterSpacing:"0.1em",
          background: files.length && !loading ? "linear-gradient(135deg,var(--accent),#0097a7)" : "var(--surface-2)",
          color: files.length && !loading ? "#000" : "var(--text-muted)", transition:"all 0.2s",
        }}>
          {loading ? `ANALYZING ${progress.done}/${progress.total}…` : `ANALYZE ${files.length||""} FILES`}
        </button>

        {loading && (
          <div style={{ marginTop:8, height:3, background:"var(--border)", borderRadius:2, overflow:"hidden" }}>
            <div style={{ height:"100%", width:`${progress.total?(progress.done/progress.total)*100:0}%`,
              background:"var(--accent)", transition:"width 0.4s ease", borderRadius:2 }} />
          </div>
        )}

        {error && (
          <div style={{ marginTop:12, padding:"10px 14px", borderRadius:8,
            background:"#ff174410", border:"1px solid #ff174440",
            color:"var(--fail)", fontFamily:"var(--mono)", fontSize:12 }}>✗ {error}</div>
        )}

        {/* results */}
        {results && !loading && (
          <div style={{ marginTop:24 }}>
            <div style={{ display:"grid", gridTemplateColumns:"repeat(3,1fr)", gap:8, marginBottom:16 }}>
              {[{label:"PASSED",value:results.passed,color:"var(--pass)"},
                {label:"FAILED",value:results.failed,color:"var(--fail)"},
                {label:"ERRORS",value:results.errored,color:"var(--warn)"}].map(({label,value,color})=>(
                <div key={label} style={{ background:"var(--surface)", border:"1px solid var(--border)",
                  borderRadius:10, padding:"14px 16px", textAlign:"center", position:"relative", overflow:"hidden" }}>
                  <div style={{ position:"absolute", top:0, left:0, right:0, height:2,
                    background:`linear-gradient(90deg,transparent,${color},transparent)` }} />
                  <div style={{ fontFamily:"var(--mono)", fontSize:24, fontWeight:700, color }}>{value}</div>
                  <div style={{ fontFamily:"var(--mono)", fontSize:10, color:"var(--text-muted)",
                    letterSpacing:"0.1em", marginTop:3 }}>{label}</div>
                </div>
              ))}
            </div>

            <div style={{ display:"flex", alignItems:"center", justifyContent:"space-between",
              marginBottom:10, gap:8, flexWrap:"wrap" }}>
              <div style={{ display:"flex", gap:5 }}>
                {["ALL","PASS","FAIL","ERROR"].map(f=>(
                  <button key={f} onClick={()=>setFilter(f)} style={{
                    padding:"4px 10px", borderRadius:6, border:"1px solid var(--border)",
                    background: filter===f ? "var(--accent)" : "var(--surface)",
                    color: filter===f ? "#000" : "var(--text-muted)",
                    fontFamily:"var(--mono)", fontSize:10, cursor:"pointer", transition:"all 0.15s",
                  }}>{f}</button>
                ))}
              </div>
              <div style={{ display:"flex", gap:6 }}>
                {[["CSV",downloadCSV],["JSON",downloadJSON]].map(([label,fn])=>(
                  <button key={label} onClick={fn} style={{
                    display:"flex", alignItems:"center", gap:5, padding:"5px 10px",
                    borderRadius:7, background:"var(--surface-2)", border:"1px solid var(--border)",
                    color:"var(--text-muted)", cursor:"pointer", fontSize:10, fontFamily:"var(--mono)" }}
                    onMouseEnter={e=>e.currentTarget.style.borderColor="var(--accent)"}
                    onMouseLeave={e=>e.currentTarget.style.borderColor="var(--border)"}>
                    <DownloadIcon /> {label}
                  </button>
                ))}
              </div>
            </div>

            <div style={{ background:"var(--surface)", border:"1px solid var(--border)", borderRadius:10, overflow:"hidden" }}>
              <div style={{ display:"grid", gridTemplateColumns:"1fr 80px 80px 80px 80px 28px",
                padding:"8px 14px", borderBottom:"1px solid var(--border)",
                fontFamily:"var(--mono)", fontSize:10, color:"var(--text-muted)", letterSpacing:"0.08em" }}>
                <span>FILE</span><span style={{textAlign:"center"}}>STATUS</span>
                <span style={{textAlign:"center"}}>WALL</span>
                <span style={{textAlign:"center"}}>OVERHANG</span>
                <span style={{textAlign:"center"}}>SEALED</span><span/>
              </div>
              {filtered.length===0 && (
                <div style={{ padding:20, textAlign:"center", color:"var(--text-muted)", fontSize:13 }}>
                  No results match.
                </div>
              )}
              {filtered.map((r,i)=>{
                const isOpen = expandedIdx===i;
                const wall=r.wall_thickness, over=r.overhangs, mesh=r.mesh_info;
                return (
                  <div key={i}>
                    <div onClick={()=>selectRowPreview(r,i)} style={{
                      display:"grid", gridTemplateColumns:"1fr 80px 80px 80px 80px 28px",
                      padding:"10px 14px", borderBottom:"1px solid var(--border)",
                      cursor:"pointer", alignItems:"center",
                      background: isOpen ? "var(--surface-2)" : "transparent",
                      transition:"background 0.15s" }}
                      onMouseEnter={e=>!isOpen&&(e.currentTarget.style.background="#ffffff08")}
                      onMouseLeave={e=>!isOpen&&(e.currentTarget.style.background="transparent")}>
                      <span style={{ fontFamily:"var(--mono)", fontSize:11, color:"var(--text)",
                        overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap" }}>{r.filename}</span>
                      <span style={{textAlign:"center"}}><StatusBadge status={r.status} small /></span>
                      <span style={{ textAlign:"center", fontFamily:"var(--mono)", fontSize:11,
                        color: wall?.min_wall_thickness_mm<1.2?"var(--fail)":"var(--pass)" }}>
                        {wall?.min_wall_thickness_mm!=null?`${wall.min_wall_thickness_mm}mm`:"—"}
                      </span>
                      <span style={{ textAlign:"center", fontFamily:"var(--mono)", fontSize:11,
                        color: over?.overhang_percentage>30?"var(--warn)":"var(--text-muted)" }}>
                        {over?.overhang_percentage!=null?`${over.overhang_percentage}%`:"—"}
                      </span>
                      <span style={{ textAlign:"center", fontFamily:"var(--mono)", fontSize:11,
                        color: mesh?.is_watertight?"var(--pass)":"var(--fail)" }}>
                        {mesh?.is_watertight!=null?(mesh.is_watertight?"YES":"NO"):"—"}
                      </span>
                      <span style={{ textAlign:"center", color:"var(--text-muted)", fontSize:14 }}>
                        {isOpen?"▲":"▼"}
                      </span>
                    </div>
                    {isOpen && (
                      <div style={{ padding:"12px 14px 14px", background:"var(--surface-2)",
                        borderBottom:"1px solid var(--border)" }}>
                        {r.status==="ERROR"
                          ? <div style={{ color:"var(--warn)", fontFamily:"var(--mono)", fontSize:11 }}>✗ {r.error}</div>
                          : <>
                            {(r.issues||[]).map((t,j)=><IssueRow key={j} text={t} type="issue"/>)}
                            {(r.warnings||[]).map((t,j)=><IssueRow key={j} text={t} type="warning"/>)}
                            {r.issues?.length===0&&r.warnings?.length===0&&
                              <div style={{color:"var(--pass)",fontFamily:"var(--mono)",fontSize:11}}>✓ No issues</div>}
                            {mesh&&(
                              <div style={{display:"flex",gap:16,marginTop:8,fontFamily:"var(--mono)",fontSize:11,color:"var(--text-muted)"}}>
                                <span>Vol: <span style={{color:"var(--text)"}}>{mesh.volume_cm3} cm³</span></span>
                                <span>BBox: <span style={{color:"var(--text)"}}>{mesh.bounding_box_mm?.x}×{mesh.bounding_box_mm?.y}×{mesh.bounding_box_mm?.z} mm</span></span>
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
      </div>

      {/* batch 3D preview panel */}
      {previewFile && (
        <div style={{ position:"sticky", top:80 }}>
          <div style={{ fontFamily:"var(--mono)", fontSize:10,
            color:"var(--text-muted)", letterSpacing:"0.1em", marginBottom:8 }}>
            3D PREVIEW — {previewFile.name}
          </div>
          <MeshViewer file={previewFile} status={previewStatus} />
          <div style={{ marginTop:6, fontFamily:"var(--mono)", fontSize:10,
            color:"var(--text-muted)", textAlign:"center" }}>
            Click any row to preview that mesh
          </div>
        </div>
      )}
    </div>
  );
}

/* ══════════════════════════════════════════════════════════════════════════ */
/* ROOT APP                                                                   */
/* ══════════════════════════════════════════════════════════════════════════ */
export default function App() {
  const [tab, setTab] = useState("single");
  return (
    <div style={{ minHeight:"100vh", background:"var(--bg)", paddingBottom:80 }}>
      <header style={{ borderBottom:"1px solid var(--border)", padding:"0 32px",
        display:"flex", alignItems:"center", justifyContent:"space-between",
        height:56, background:"var(--surface)", position:"sticky", top:0, zIndex:10 }}>
        <div style={{ display:"flex", alignItems:"center", gap:10 }}>
          <LayersIcon />
          <span style={{ fontFamily:"var(--mono)", fontWeight:700, fontSize:13,
            letterSpacing:"0.08em", color:"var(--accent)" }}>FDM CHECKER</span>
        </div>
        <div style={{ fontFamily:"var(--mono)", fontSize:11, color:"var(--text-muted)" }}>v1.2 · localhost</div>
      </header>

      <div style={{ padding:"44px 32px 0", maxWidth:1100, margin:"0 auto" }}>
        <div style={{ marginBottom:6, fontFamily:"var(--mono)", fontSize:11,
          color:"var(--accent)", letterSpacing:"0.15em" }}>FDM PRINTABILITY ANALYSIS</div>
        <h1 style={{ fontSize:"clamp(24px,5vw,40px)", fontWeight:300,
          lineHeight:1.1, marginBottom:8, color:"var(--text)" }}>
          Will your model<br />
          <em style={{ fontStyle:"italic", color:"var(--accent)" }}>actually print?</em>
        </h1>
        <p style={{ color:"var(--text-muted)", fontSize:15, lineHeight:1.6,
          marginBottom:28, maxWidth:500 }}>
          Upload a mesh — preview it in 3D instantly, then analyze printability.
        </p>

        <div style={{ display:"flex", gap:4, marginBottom:24, background:"var(--surface)",
          border:"1px solid var(--border)", borderRadius:10, padding:4, width:"fit-content" }}>
          {[{id:"single",label:"Single File"},{id:"batch",label:"⚡ Batch (Pro)"}].map(({id,label})=>(
            <button key={id} onClick={()=>setTab(id)} style={{
              padding:"6px 18px", borderRadius:7, border:"none", cursor:"pointer",
              fontFamily:"var(--mono)", fontSize:12, fontWeight:700, letterSpacing:"0.05em",
              background: tab===id ? (id==="batch"?"var(--accent)":"var(--surface-2)") : "transparent",
              color: tab===id ? (id==="batch"?"#000":"var(--text)") : "var(--text-muted)",
              transition:"all 0.15s",
            }}>{label}</button>
          ))}
        </div>

        {tab==="single" ? <SingleMode /> : <BatchMode />}
      </div>
    </div>
  );
}