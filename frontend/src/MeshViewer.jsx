import { useEffect, useRef, useState } from "react";
import * as THREE from "three";
import { STLLoader } from "three/addons/loaders/STLLoader.js";
import { OBJLoader } from "three/addons/loaders/OBJLoader.js";
import { PLYLoader } from "three/addons/loaders/PLYLoader.js";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";

const STATUS_COLOR = { PASS: 0x00e676, FAIL: 0xff1744, WARN: 0xffd740, null: 0x00e5ff };

export default function MeshViewer({ file, status }) {
  const mountRef  = useRef(null);
  const stateRef  = useRef({});
  const [loading, setLoading]   = useState(false);
  const [error,   setError]     = useState(null);
  const [info,    setInfo]      = useState(null);
  const [wire,    setWire]      = useState(false);

  useEffect(() => {
    const el = mountRef.current;
    if (!el) return;

    const W = el.clientWidth, H = el.clientHeight;

    const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
    renderer.setSize(W, H);
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.setClearColor(0x0a0a0f, 1);
    el.appendChild(renderer.domElement);

    const scene  = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(45, W / H, 0.001, 1000);
    camera.position.set(0, 0, 3);

    const amb  = new THREE.AmbientLight(0xffffff, 0.5);
    const dir1 = new THREE.DirectionalLight(0xffffff, 1.0);
    dir1.position.set(3, 5, 4);
    const dir2 = new THREE.DirectionalLight(0x4488ff, 0.3);
    dir2.position.set(-3, -2, -4);
    scene.add(amb, dir1, dir2);

    const grid = new THREE.GridHelper(6, 10, 0x1a1a2e, 0x14141f);
    scene.add(grid);

    const controls = new OrbitControls(camera, renderer.domElement);
    controls.enableDamping    = true;
    controls.dampingFactor    = 0.08;
    controls.minDistance      = 0.5;
    controls.maxDistance      = 20;
    controls.enablePan        = true;
    controls.autoRotate       = true;
    controls.autoRotateSpeed  = 1.2;
    controls.addEventListener("start", () => { controls.autoRotate = false; });

    let animId;
    const animate = () => {
      animId = requestAnimationFrame(animate);
      controls.update();
      renderer.render(scene, camera);
    };
    animate();

    const onResize = () => {
      const W2 = el.clientWidth, H2 = el.clientHeight;
      camera.aspect = W2 / H2;
      camera.updateProjectionMatrix();
      renderer.setSize(W2, H2);
    };
    window.addEventListener("resize", onResize);

    stateRef.current = { renderer, scene, camera, controls, grid, animId };

    return () => {
      cancelAnimationFrame(animId);
      window.removeEventListener("resize", onResize);
      controls.dispose();
      renderer.dispose();
      if (el.contains(renderer.domElement)) el.removeChild(renderer.domElement);
    };
  }, []);

  useEffect(() => {
    if (!file) return;
    const { scene, camera, controls, grid } = stateRef.current;
    if (!scene) return;

    setLoading(true);
    setError(null);
    setInfo(null);

    scene.children
      .filter(c => c.userData.isMesh)
      .forEach(c => {
        scene.remove(c);
        c.geometry?.dispose();
        c.material?.dispose();
      });

    const ext  = file.name.split(".").pop().toLowerCase();
    const url  = URL.createObjectURL(file);

    const onGeo = (geometry) => {
      URL.revokeObjectURL(url);
      geometry.computeVertexNormals();
      geometry.center();

      geometry.computeBoundingSphere();
      const r = geometry.boundingSphere.radius;
      camera.position.set(0, r * 0.6, r * 2.8);
      controls.target.set(0, 0, 0);
      controls.minDistance = r * 0.5;
      controls.maxDistance = r * 20;
      controls.autoRotate  = true;

      geometry.computeBoundingBox();
      const minY = geometry.boundingBox.min.y;
      grid.position.y = minY - r * 0.05;

      const accentColor = STATUS_COLOR[status] ?? STATUS_COLOR[null];

      const mat = new THREE.MeshPhongMaterial({
        color:            accentColor,
        emissive:         accentColor,
        emissiveIntensity: 0.04,
        shininess:        55,
        side:             THREE.DoubleSide,
        transparent:      wire,
        opacity:          wire ? 0.12 : 0.9,
      });
      const solidMesh = new THREE.Mesh(geometry, mat);
      solidMesh.userData.isMesh = true;

      const edges   = new THREE.EdgesGeometry(geometry, 25);
      const wireMat = new THREE.LineBasicMaterial({
        color:       0xffffff,
        transparent: true,
        opacity:     wire ? 0.85 : 0.12,
      });
      const edgeMesh = new THREE.LineSegments(edges, wireMat);
      edgeMesh.userData.isMesh = true;

      scene.add(solidMesh, edgeMesh);
      stateRef.current.solidMesh = solidMesh;
      stateRef.current.edgeMesh  = edgeMesh;

      const bb  = geometry.boundingBox;
      const ex  = [
        bb.max.x - bb.min.x,
        bb.max.y - bb.min.y,
        bb.max.z - bb.min.z,
      ].map(v => v.toFixed(2));
      const vc = geometry.attributes.position.count;
      const fc = geometry.index
        ? geometry.index.count / 3
        : vc / 3;
      setInfo({ verts: Math.round(vc), faces: Math.round(fc), extents: ex });
      setLoading(false);
    };

    const onErr = (e) => {
      URL.revokeObjectURL(url);
      setError(`Could not parse ${ext.toUpperCase()} file.`);
      setLoading(false);
    };

    if (ext === "stl") {
      new STLLoader().load(url, onGeo, undefined, onErr);
    } else if (ext === "obj") {
      new OBJLoader().load(url, (obj) => {
        let geo = null;
        obj.traverse(c => { if (c.isMesh && !geo) geo = c.geometry; });
        geo ? onGeo(geo) : onErr();
      }, undefined, onErr);
    } else if (ext === "ply") {
      new PLYLoader().load(url, onGeo, undefined, onErr);
    } else {
      setError(`Browser preview not supported for .${ext} — analysis still works.`);
      setLoading(false);
    }
  }, [file]);

  useEffect(() => {
    const { solidMesh, edgeMesh } = stateRef.current;
    if (!solidMesh) return;
    const col = STATUS_COLOR[status] ?? STATUS_COLOR[null];
    solidMesh.material.color.setHex(col);
    solidMesh.material.emissive.setHex(col);
  }, [status]);

  const toggleWire = () => {
    const { solidMesh, edgeMesh } = stateRef.current;
    if (!solidMesh) return;
    const next = !wire;
    setWire(next);
    solidMesh.material.transparent = next;
    solidMesh.material.opacity     = next ? 0.10 : 0.9;
    edgeMesh.material.opacity      = next ? 0.85 : 0.12;
  };

  const resetCam = () => {
    const { controls } = stateRef.current;
    if (!controls) return;
    controls.reset();
    controls.autoRotate = true;
  };

  const accentColor = status === "PASS" ? "var(--pass)"
    : status === "FAIL" ? "var(--fail)"
    : status === "WARN" ? "var(--warn)"
    : "var(--accent)";

  return (
    <div style={{ position: "relative", borderRadius: 12, overflow: "hidden",
      border: `1px solid ${status ? accentColor : "var(--border)"}`,
      transition: "border-color 0.4s", background: "#0a0a0f" }}>

      <div ref={mountRef} style={{ width: "100%", height: 320 }} />

      {loading && (
        <div style={{ position: "absolute", inset: 0, display: "flex",
          flexDirection: "column", alignItems: "center", justifyContent: "center",
          background: "#0a0a0f", gap: 12 }}>
          <div style={{ width: 36, height: 36, border: "2px solid var(--border)",
            borderTop: "2px solid var(--accent)", borderRadius: "50%",
            animation: "spin-slow 0.9s linear infinite" }} />
          <span style={{ fontFamily: "var(--mono)", fontSize: 11,
            color: "var(--accent)", letterSpacing: "0.1em" }}>PARSING MESH…</span>
        </div>
      )}

      {error && !loading && (
        <div style={{ position: "absolute", inset: 0, display: "flex",
          alignItems: "center", justifyContent: "center",
          background: "#0a0a0f", padding: 24, textAlign: "center" }}>
          <span style={{ fontFamily: "var(--mono)", fontSize: 12,
            color: "var(--warn)" }}>⚠ {error}</span>
        </div>
      )}

      {!file && !loading && !error && (
        <div style={{ position: "absolute", inset: 0, display: "flex",
          flexDirection: "column", alignItems: "center", justifyContent: "center",
          pointerEvents: "none", gap: 8 }}>
          <svg width="32" height="32" viewBox="0 0 24 24" fill="none"
            stroke="var(--text-muted)" strokeWidth="1.2">
            <path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/>
          </svg>
          <span style={{ fontFamily: "var(--mono)", fontSize: 11,
            color: "var(--text-muted)", letterSpacing: "0.08em" }}>
            3D PREVIEW
          </span>
        </div>
      )}

      {file && !error && (
        <div style={{ position: "absolute", top: 10, right: 10,
          display: "flex", flexDirection: "column", gap: 6 }}>
          {[
            { label: "⬡", title: "Wireframe", action: toggleWire, active: wire },
            { label: "⌖", title: "Reset camera", action: resetCam, active: false },
          ].map(({ label, title, action, active }) => (
            <button key={title} onClick={action} title={title} style={{
              width: 28, height: 28, borderRadius: 6, border: "1px solid",
              borderColor: active ? "var(--accent)" : "#ffffff20",
              background:  active ? "var(--accent-dim)" : "#ffffff0c",
              color:       active ? "var(--accent)" : "#ffffffaa",
              fontSize: 14, cursor: "pointer", display: "flex",
              alignItems: "center", justifyContent: "center",
              fontFamily: "var(--mono)",
            }}>{label}</button>
          ))}
        </div>
      )}

      {info && (
        <div style={{
          position: "absolute", bottom: 0, left: 0, right: 0,
          padding: "6px 14px",
          background: "linear-gradient(transparent, #0a0a0fcc)",
          display: "flex", gap: 16,
          fontFamily: "var(--mono)", fontSize: 10,
          color: "var(--text-muted)", pointerEvents: "none",
        }}>
          <span>VERTS <span style={{color:"var(--text)"}}>{info.verts.toLocaleString()}</span></span>
          <span>FACES <span style={{color:"var(--text)"}}>{info.faces.toLocaleString()}</span></span>
          <span>BBOX <span style={{color:"var(--accent)"}}>{info.extents.join(" × ")}</span></span>
          <span style={{marginLeft:"auto"}}>drag · scroll · right-drag pan</span>
        </div>
      )}
    </div>
  );
}