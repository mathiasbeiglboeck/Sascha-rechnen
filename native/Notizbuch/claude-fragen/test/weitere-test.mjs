// Test von weitere-seiten.mjs ohne Server: die reinen Funktionen, das PDF einer Seite (pdfinfo, pdftoppm), und der Teil
// mit Zustand mit einem nachgebauten Server (Route /api/doc/<id>/strokes: since, limit, more, top, meta) und
// fake-osascript statt macOS (braucht poppler: pdfinfo, pdftoppm). Am Ende Messungen (Zeit und Größe einer Seite).
//   node native/Notizbuch/claude-fragen/test/weitere-test.mjs
import { execFile, execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import zlib from "node:zlib";
import { fileURLToPath } from "node:url";
import * as W from "../weitere-seiten.mjs";

const S = path.dirname(fileURLToPath(import.meta.url));
const FAKE_OSASCRIPT = path.join(S, "fake-osascript");
const TMP = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), "bn-weitere-test-"));
const { GAP, A4H, GRID, BAND } = W.LAYOUT;
const DAY = 86400000, WEEK = 7 * DAY, HOUR = 3600000, MIN = 60000;
let passes = 0, failures = 0;
const ok = (c, m, x) => { if (c) { passes++; console.log("  ok  ", m); } else { failures++; console.log("  FAIL", m, x !== undefined ? JSON.stringify(x).slice(0, 500) : ""); } };
const near = (a, b, eps = 0.01) => Math.abs(a - b) <= eps;
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const top = (i) => GAP + i * (A4H + GAP); // Oberkante der Notizbuchseite i (ab 0)

// ---------- Hilfen ----------

/// Ein Strich wie aus der App (10 Werte je Punkt, Zweitskala 0,5: gezeichnete Breite = w) oder mit 9 Werten
function wire({ x = 100, y, len = 200, dy = 0, w = 2, ink = "com.apple.ink.pen", c = [0, 0, 0, 1], n = 8, nine = false, extra = {} }) {
  const p = [];
  for (let k = 0; k < n; k++) {
    const t = n === 1 ? 0 : k / (n - 1);
    const q = [+(x + len * t).toFixed(2), +(y + dy * t).toFixed(2), +(k * 0.01).toFixed(3), w, w, 1, 0.5, 0.8, 1.2];
    p.push(nine ? q : [...q, 0.5]);
  }
  return JSON.stringify({ c, ink, p, pk: "QUJDRA==", ...extra });
}

function httpError(status, body) {
  return Object.assign(new Error(`HTTP ${status}`), { status, body });
}

/// Nachbau der Route GET /api/doc/<id>/strokes?since&limit&lite=1 über einer Tabelle wie am Server (eine Zeile je
/// Strich, Löschen als Grabstein, seq für alle Dokumente gemeinsam). delayMs: jede Antwort so viel später (ein
/// signal bricht das Warten ab wie fetch)
function fakeServer() {
  let seq = 0;
  const docs = new Map();
  const srv = {
    calls: [], mode: null, delayMs: 0,
    doc(id) {
      if (!docs.has(id)) docs.set(id, { meta: { kind: "notebook", pageCount: 2, pagesVersion: 0, pdfVersion: 0, layoutVersion: 2, title: "geheim" }, rows: new Map() });
      return docs.get(id);
    },
    add(id, sid, data) { srv.doc(id).rows.set(sid, { data, alive: 1, seq: ++seq }); },
    remove(id, sid) { srv.doc(id).rows.set(sid, { data: null, alive: 0, seq: ++seq }); },
    wipe(id) { srv.doc(id).rows.clear(); },
    meta(id, m) { Object.assign(srv.doc(id).meta, m); },
    async api(method, p, opts = {}) {
      srv.calls.push({ method, p, timeout: opts.timeout, signal: Boolean(opts.signal) });
      if (srv.delayMs) {
        await new Promise((resolve, reject) => {
          const t = setTimeout(resolve, srv.delayMs);
          opts.signal?.addEventListener("abort", () => { clearTimeout(t); reject(Object.assign(new Error("This operation was aborted"), { name: "AbortError" })); }, { once: true });
        });
      }
      if (srv.mode === "404") throw httpError(404, { error: "Unbekannte Adresse" });
      if (srv.mode === "404code") throw httpError(404, { error: "Gibt es nicht", code: "missing" });
      if (srv.mode === "500") throw httpError(500, { error: "kaputt" });
      if (srv.mode === "net") throw new TypeError("fetch failed");
      if (srv.mode === "ENOSPC") throw Object.assign(new Error("no space left on device"), { code: "ENOSPC" });
      const m = /^\/api\/doc\/([^/?]+)\/strokes\?(.*)$/.exec(p);
      if (method !== "GET" || !m) throw httpError(404, { error: "Unbekannte Adresse" });
      const q = new URLSearchParams(m[2]);
      const since = Number(q.get("since")) || 0, limit = Math.min(1000, Math.max(1, Number(q.get("limit")) || 500));
      const d = docs.get(m[1]);
      const all = d ? [...d.rows].map(([id, r]) => ({ id, ...r })) : [];
      const rows = all.filter((r) => r.seq > since).sort((a, b) => a.seq - b.seq);
      const lite = (data) => { if (q.get("lite") !== "1") return data; const o = JSON.parse(data); delete o.pk; return JSON.stringify(o); };
      // Wie der Server: höchstens limit Zeilen, deren data (wie zurückgegeben) zusammen höchstens 1.000.000 Zeichen hat,
      // aber mindestens eine
      const out = [];
      let chars = 0;
      for (const r of rows) {
        const n = r.alive && r.data ? lite(r.data).length : 0;
        if (out.length >= limit || (out.length && chars + n > 1e6)) break;
        out.push(r);
        chars += n;
      }
      const meta = d ? (({ kind, pageCount, pagesVersion, pdfVersion, layoutVersion, deleted }) => ({ kind, pageCount, pagesVersion, pdfVersion, layoutVersion, ...(deleted ? { deleted } : {}) }))(d.meta) : null;
      return {
        data: {
          top: all.reduce((a, r) => Math.max(a, r.seq), 0), low: all.length ? Math.min(...all.map((r) => r.seq)) : 0,
          last: out.length ? out.at(-1).seq : since, more: out.length < rows.length, meta,
          changes: out.map((r) => ({ id: r.id, seq: r.seq, data: r.alive ? lite(r.data) : null })),
        },
        type: "application/json",
      };
    },
  };
  return srv;
}

/// create() mit nachgebautem Server, eigener Uhr (clock.t) und fake-osascript; FAKE_STATE je Instanz
function harness({ cfg = {}, home, fake, srv, clock = { t: Date.now() }, warmBatchMs } = {}) {
  const HOME = home || fs.mkdtempSync(path.join(TMP, "home-"));
  const FAKE = fake || fs.mkdtempSync(path.join(TMP, "fake-"));
  const logs = [], osaCalls = [];
  const state = { docs: {} };
  const server = srv || fakeServer();
  let saves = 0;
  const runOsascript = (args, { timeout, signal }) => new Promise((resolve, reject) => {
    osaCalls.push(args);
    execFile(FAKE_OSASCRIPT, args, { timeout, env: { PATH: process.env.PATH, FAKE_STATE: FAKE }, ...(signal ? { signal } : {}) },
      (err, stdout, stderr) => (err ? reject(new Error((stderr || err.message).trim())) : resolve(stdout.trim())));
  });
  const w = W.create({
    HOME, api: server.api, log: (...p) => logs.push(p.join(" ")), runOsascript, getConfig: () => cfg, state,
    saveState: () => saves++, now: () => clock.t, ...(warmBatchMs ? { warmBatchMs } : {}),
  });
  return { HOME, FAKE, logs, osaCalls, state, srv: server, clock, cfg, w, saves: () => saves };
}

let askNo = 0;
/// Frage auf Seite q (ab 0) eines Dokuments; files wie fetchFiles (span ab 1)
async function ask(h, doc, q, { files = {}, deadline, isCancelled, effort = "quick", pv, docExtra = {} } = {}) {
  const id = `ASK-${++askNo}`;
  const dir = path.join(h.HOME, "chats", doc), qdir = path.join(dir, "fragen", id);
  fs.mkdirSync(qdir, { recursive: true });
  const job = { id, doc: { id: doc, kind: "notebook", title: "Test", pageCount: 2, ...docExtra }, anchor: { page: q }, pv: pv ?? (h.srv.doc(doc).meta.pagesVersion || 0), effort };
  const r = await h.w.prepare(job, files, { qdir, dir, deadline: deadline ?? h.clock.t + 15000, isCancelled });
  return { r, qdir, dir, id };
}

const calls = (fake) => { try { return fs.readFileSync(path.join(fake, "calls.jsonl"), "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)); } catch { return []; } };
const ls = (dir) => { try { return fs.readdirSync(dir).sort(); } catch { return []; } };
const cacheFiles = (h, doc) => ls(path.join(h.HOME, "seitenbilder", doc)).filter((f) => f.endsWith(".pdf"));
const stand = (h, doc) => JSON.parse(fs.readFileSync(path.join(h.HOME, "spiegel", doc, "stand.json"), "utf8"));

let tools = true;
try { execFileSync("pdftoppm", ["-v"], { stdio: "ignore" }); execFileSync("pdfinfo", ["-v"], { stdio: "ignore" }); } catch { tools = false; }

/// Rendert ein PDF mit pdftoppm (72 dpi: 1 Pixel je Punkt) und gibt Pixel zurück
function raster(pdf, name, dpi = 72) {
  const f = path.join(TMP, `${name}.pdf`);
  fs.writeFileSync(f, pdf);
  execFileSync("pdftoppm", ["-r", String(dpi), "-singlefile", f, path.join(TMP, name)]);
  const buf = fs.readFileSync(path.join(TMP, `${name}.ppm`));
  const m = /^P6\s+(\d+)\s+(\d+)\s+255\s/.exec(buf.subarray(0, 40).toString("latin1"));
  const w = Number(m[1]), h = Number(m[2]), off = m[0].length;
  const px = (x, y) => { const i = off + 3 * (Math.round(y) * w + Math.round(x)); return [buf[i], buf[i + 1], buf[i + 2]]; };
  // dunkelster Wert (Summe der Kanäle) in einem Rechteck
  const darkest = (x0, y0, x1, y1) => { let best = 999; for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) { const p = px(x, y); best = Math.min(best, p[0] + p[1] + p[2]); } return best; };
  return { w, h, px, darkest };
}

function pdfinfo(pdf, name) {
  const f = path.join(TMP, `${name}.pdf`);
  fs.writeFileSync(f, pdf);
  return execFileSync("pdfinfo", [f], { encoding: "utf8" });
}

/// Querverweise stimmen: jeder Eintrag zeigt auf „n 0 obj“, startxref auf „xref“, /Length auf das Ende des Streams
function xrefOK(buf) {
  const s = buf.toString("latin1");
  const sx = Number(/startxref\n(\d+)\n%%EOF\n$/.exec(s)?.[1]);
  if (!(sx > 0) || s.slice(sx, sx + 5) !== "xref\n") return false;
  const m = /^xref\n0 (\d+)\n/.exec(s.slice(sx));
  let pos = sx + m[0].length;
  for (let i = 0; i < Number(m[1]); i++, pos += 20) {
    const e = s.slice(pos, pos + 20);
    if (i === 0 ? e !== "0000000000 65535 f \n" : !/^\d{10} 00000 n \n$/.test(e) || !s.startsWith(`${i} 0 obj\n`, Number(e.slice(0, 10)))) return false;
  }
  for (const mm of s.matchAll(/\/Length (\d+)[^>]*>>\nstream\n/g)) {
    if (s.slice(mm.index + mm[0].length + Number(mm[1]), mm.index + mm[0].length + Number(mm[1]) + 10) !== "\nendstream") return false;
  }
  return true;
}

/// Der (entpackte) Inhalt der Seite
function contentOf(pdf) {
  const s = pdf.toString("latin1");
  const m = /4 0 obj\n<< \/Length (\d+) \/Filter \/FlateDecode >>\nstream\n/.exec(s);
  const start = m.index + m[0].length;
  return zlib.inflateSync(pdf.subarray(start, start + Number(m[1]))).toString("latin1");
}

/// Kleines PDF mit Seiten der Größe [w, h] (Punkte), optional gedreht; jede mit einem blauen Rechteck oben links und
/// einem schwarzen Balken in der Mitte
function makePDF(pages) {
  const objs = ["<< /Type /Catalog /Pages 2 0 R >>", null];
  const kids = [];
  for (const { size: [w, h], rotate } of pages) {
    const stream = `0 0 1 rg 0 ${h - h / 4} ${w / 4} ${h / 4} re f 0 0 0 rg ${w / 4} ${h / 2 - 10} ${w / 2} 20 re f\n`;
    objs.push(`<< /Length ${stream.length} >>\nstream\n${stream}endstream`);
    objs.push(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${w} ${h}]${rotate ? ` /Rotate ${rotate}` : ""} /Contents ${objs.length} 0 R /Resources << >> >>`);
    kids.push(objs.length);
  }
  objs[1] = `<< /Type /Pages /Kids [${kids.map((k) => `${k} 0 R`).join(" ")}] /Count ${kids.length} >>`;
  let out = "%PDF-1.4\n";
  const offs = [];
  objs.forEach((o, i) => { offs.push(out.length); out += `${i + 1} 0 obj\n${o}\nendobj\n`; });
  const x = out.length;
  out += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n${offs.map((o) => `${String(o).padStart(10, "0")} 00000 n \n`).join("")}trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${x}\n%%EOF\n`;
  return Buffer.from(out, "latin1");
}

/// JPEG einer Seite eines PDFs in genau pw × ph Pixeln (pdftoppm)
function jpegOf(pdf, page, pw, ph) {
  const f = path.join(TMP, "jpegsrc.pdf");
  fs.writeFileSync(f, pdf);
  execFileSync("pdftoppm", ["-jpeg", "-jpegopt", "quality=60", "-cropbox", "-scale-dimension-before-rotation", "-f", String(page + 1), "-l", String(page + 1), "-scale-to-x", String(pw), "-scale-to-y", String(ph), "-singlefile", f, path.join(TMP, "jpegout")]);
  return fs.readFileSync(path.join(TMP, "jpegout.jpg"));
}

// ---------- Reine Funktionen ----------

function pureTests() {
  console.log("== compactStroke");
  let st = W.compactStroke(wire({ x: 10, y: 20, len: 20, w: 4, n: 3 }));
  ok(st && st.k === "com.apple.ink.pen" && same(st.c, [0, 0, 0, 1]) && st.p.length === 9, "gültig: Tinte, Farbe, 3 Punkte × 3 Werte", st);
  ok(st && same(st.p, [10, 20, 4, 20, 20, 4, 30, 20, 4]), "10 Werte: Breite = Breite × Zweitskala × 2", st?.p);
  ok(st && same(st.b, [8, 18, 32, 22]), "Rahmen: Punkte ± halbe größte Breite", st?.b);
  const browser = JSON.parse(wire({ x: 10, y: 20, len: 20, w: 4, n: 3, nine: true }));
  browser.p = browser.p.map((q) => [...q.slice(0, 5), 1, 1, 0, 1.571]);
  st = W.compactStroke(JSON.stringify(browser));
  ok(st && st.p[2] === 4 && st.p.length === 9, "9 Werte aus dem Browser (1, 1, 0, 1,571): Breite = Breite", st?.p);
  st = W.compactStroke(wire({ x: 10, y: 20, len: 20, w: 4, n: 3, nine: true }));
  ok(st && st.p[2] === 1.57 && st.p.length === 9, "9 Werte aus der App vor der Zweitskala: 0,69 + 0,22 × 4 = 1,57", st?.p);
  st = W.compactStroke(wire({ x: 10, y: 20, len: 20, w: 0.5, n: 3, nine: true }));
  ok(st && st.p[2] === 0.5, "… nie dicker als die Breite selbst", st?.p);
  const ten = JSON.parse(wire({ x: 0, y: 0, n: 2 }));
  ten.p[0][9] = 0.25; ten.p[1][9] = 0.25;
  st = W.compactStroke(JSON.stringify(ten));
  ok(st && st.p[2] === 1, "Zweitskala 0,25 bei Breite 2: 1", st?.p);
  ok(W.compactStroke("{kaputt") === null && W.compactStroke(null) === null && W.compactStroke('{"p":[]}') === null && W.compactStroke('{"c":[0,0,0,1]}') === null, "kaputtes JSON, null, ohne Punkte: null");
  const bad = (f) => { const o = JSON.parse(wire({ y: 50, n: 3 })); f(o); return W.compactStroke(JSON.stringify(o)); };
  ok(bad((o) => { o.p[1] = o.p[1].slice(0, 8); }) === null, "8 Werte in einem Punkt: null");
  ok(bad((o) => { o.p[1][1] = "12"; }) === null && bad((o) => { o.p[2][3] = null; }) === null, "Text oder null statt Zahl: null");
  ok(bad((o) => { o.p[0][0] = 1e12; }) === null && bad((o) => { o.p[0][3] = -1; }) === null, "unsinnige Koordinate oder negative Breite: null");
  ok(bad((o) => { o.p = Array.from({ length: 20001 }, (_, k) => [k / 100, 10, 0, 1, 1, 1, 0, 0, 0]); }) === null, "mehr als 20.000 Punkte: null");
  ok(bad((o) => { o.p = Array.from({ length: 20000 }, (_, k) => [k / 100, 10, 0, 1, 1, 1, 0, 0, 0]); }) !== null, "20.000 Punkte: gültig");
  st = W.compactStroke(wire({ y: 50, c: [1.5, -0.2, 0.5] }));
  ok(st && same(st.c, [1, 0, 0.5, 1]), "Farbe auf 0…1, Deckkraft ohne Angabe 1", st?.c);
  st = W.compactStroke(wire({ y: 50, c: [0.2, 0.2, 0.2, 0.3] }));
  ok(st && st.c[3] === 0.3, "Deckkraft 0,3", st?.c);
  ok(W.compactStroke(wire({ y: 50, c: "rot" }))?.c.join() === "0,0,0,1", "Farbe kein Feld: schwarz");
  const moved = W.compactStroke(wire({ x: 10, y: 20, n: 3, extra: { dx: 100, dy: 50 } }));
  ok(moved && moved.p[0] === 10 && moved.p[1] === 20, "dx/dy gelten nur für pk, die Punkte bleiben", moved?.p);
  const a = W.compactStroke(wire({ x: 10, y: 20 })), b = W.compactStroke(wire({ x: 10, y: 1120 }));
  const c = W.compactStroke(wire({ x: 10.5, y: 1120 })), d = W.compactStroke(wire({ x: 10, y: 20, c: [1, 0, 0, 1] }));
  const e = W.compactStroke(wire({ x: 10, y: 20, ink: "com.apple.ink.marker" }));
  ok(a.s === b.s && a.s !== c.s && a.s !== d.s && a.s !== e.s && /^[0-9a-f]{16}$/.test(a.s), "Kennzahl s: gleich bei nur senkrecht verschoben, sonst verschieden");
  ok(e.k === "com.apple.ink.marker", "Tinte als k");

  console.log("== Seiten");
  const nf = W.notebookFrames(3);
  ok(nf.length === 3 && nf[0].y === GAP && near(nf[1].y, GAP + A4H + GAP) && near(nf[2].y, GAP + 2 * (A4H + GAP)) && nf.every((f) => f.h === A4H), "notebookFrames: A4 untereinander, 6 Abstand", nf);
  ok(W.notebookFrames(0).length === 1, "mindestens eine Seite");
  const pf = W.pdfFrames([100, 200, 50]);
  ok(same(pf, [{ y: 6, h: 100 }, { y: 112, h: 200 }, { y: 318, h: 50 }]), "pdfFrames wie PageLayout.stack", pf);

  console.log("== inkByPage");
  const border = W.compactStroke(wire({ x: 50, y: top(0) + A4H - 8, dy: 20, len: 30, w: 2 })); // 0: bis 8 + 1 über die Kante, 1: 13 − 6
  const tiny = W.compactStroke(wire({ x: 400, y: top(1) - 0.7, len: 30, w: 0 })); // ragt 0,3 in Seite 1 hinein? Nein: Abstand
  const onPage1 = W.compactStroke(wire({ x: 100, y: top(1) + 100 }));
  const touch1 = W.compactStroke(wire({ x: 300, y: top(0) + A4H - 50, dy: 50 + GAP + 0.3, len: 10, w: 0 })); // 0,3 auf Seite 1
  const nbFrames = W.notebookFrames(2);
  let map = W.inkByPage([border, tiny, onPage1, touch1], nbFrames);
  ok(map.get(0)?.includes(border) && map.get(1)?.includes(border), "Strich über die Seitengrenze: auf beiden Seiten");
  ok(map.get(0)?.includes(touch1) && !map.get(1)?.includes(touch1), "nur 0,3 Punkte auf der nächsten Seite: nicht dort");
  ok(!map.get(0)?.includes(tiny) && !map.get(1)?.includes(tiny), "im Abstand zwischen den Seiten: auf keiner");
  ok(same(map.get(1).map((x) => x === border ? "b" : x === onPage1 ? "p" : "?"), ["b", "p"]), "Reihenfolge wie gegeben (seq)");
  const far = W.compactStroke(wire({ x: 100, y: top(5) + 300 }));
  map = W.inkByPage([onPage1, far], nbFrames);
  ok(!map.has(5) && map.size === 1, "PDF: Tinte unter der letzten Seite fällt weg");
  map = W.inkByPage([onPage1, far], nbFrames, { grow: true });
  ok(map.has(5) && map.get(5)[0] === far && map.has(1), "Notizbuch (grow): Seiten wachsen bis zur Tinte", [...map.keys()]);
  const hair = W.compactStroke(wire({ x: 100, y: top(1) + 400, len: 300, w: 0.3, nine: true }));
  const corner = W.compactStroke(wire({ x: 100, y: top(0) + A4H - 0.3, dy: 0.2, len: 1, w: 0, nine: true }));
  const topTiny = W.compactStroke(wire({ x: 100, y: top(3) + 0.1, dy: 0.2, len: 1, w: 0, nine: true }));
  map = W.inkByPage([hair, corner], nbFrames);
  ok(map.get(1)?.includes(hair) && map.get(0)?.includes(corner) && map.size === 2, "waagrechter Haarstrich (0,3 hoch) und Winzling am Seitenende: auf ihrer Seite", [...map].map(([k, v]) => [k, v.length]));
  map = W.inkByPage([topTiny], W.notebookFrames(1), { grow: true });
  ok(same([...map.keys()], [3]), "Winzling oben auf Seite 3: Seiten wachsen bis dorthin", [...map.keys()]);
  const pdfMap = W.inkByPage([W.compactStroke(wire({ x: 10, y: 120 }))], pf);
  ok(same([...pdfMap.keys()], [1]), "PDF-Seiten verschiedener Höhe");

  console.log("== movingFrom");
  const now = Date.now();
  const strokesOn = (pages, shift = 0, xoff = 0) => pages.flatMap((pi) => [0, 1, 2].map((k) => W.compactStroke(wire({ x: 40 + pi * 13 + k * 101 + xoff, y: top(pi) + 100 + k * 80 + shift, len: 50 + k * 7 + pi }))));
  const base = strokesOn([0, 1, 2, 3, 4, 5]);
  const copies = strokesOn([3, 4, 5], A4H + GAP);
  const frames8 = W.notebookFrames(8);
  ok(W.movingFrom([...base, ...copies], frames8, { pagesVersion: now - 5 * MIN, now }) === 3, "Zwillinge (Seite eingefügt) innerhalb von 30 Minuten: ab Seite 3 (ab 0)");
  ok(W.movingFrom([...base, ...copies], frames8, { pagesVersion: now - 31 * MIN, now }) === null, "älter als 30 Minuten: null");
  ok(W.movingFrom([...base, ...copies], frames8, { pagesVersion: 0, now }) === null, "ohne Seitenänderung: null");
  ok(W.movingFrom([...base, ...strokesOn([3, 4, 5], A4H + GAP, 0.5)], frames8, { pagesVersion: now - 5 * MIN, now }) === null, "Kopien mit x-Versatz: keine Zwillinge");
  ok(W.movingFrom([...base, ...strokesOn([3], A4H + GAP).slice(0, 2)], frames8, { pagesVersion: now - 5 * MIN, now }) === null, "nur zwei Paare: null");
  ok(W.movingFrom([...base, ...strokesOn([3, 4, 5], 120)], frames8, { pagesVersion: now - 5 * MIN, now }) === null, "weniger als 300 Punkte auseinander: null");
  const up = strokesOn([4, 5], -(A4H + GAP)); // Seite 3 gelöscht: 4, 5 rücken nach oben
  ok(W.movingFrom([...strokesOn([0, 1, 2, 4, 5]), ...up], frames8, { pagesVersion: now - MIN, now }) === 3, "Seite gelöscht (nach oben): ab der ersten berührten Seite");

  console.log("== chooseMore");
  let cm = W.chooseMore({ q: 5, written: [0, 1, 3, 4, 5, 6, 7, 9, 12] });
  ok(same(cm.offer, [4, 6, 3, 7, 1, 9, 0, 12]) && same(cm.over, []), "die nächsten zuerst, gleich weit: davor zuerst, ohne die Frage", cm);
  cm = W.chooseMore({ q: 5, written: [0, 1, 3, 4, 5, 6, 7, 9, 12], covered: [3, 4, 5, 6], withheldFrom: 9 });
  ok(same(cm.offer, [7, 1, 0]), "ohne gezeigte, ohne die ab withheldFrom", cm);
  cm = W.chooseMore({ q: 0, written: Array.from({ length: 10 }, (_, i) => i), max: 4 });
  ok(same(cm.offer, [1, 2, 3, 4]) && same(cm.over, [5, 6, 7, 8, 9]), "höchstens max, der Rest in over", cm);
  ok(W.chooseMore({ q: 2, written: [2] }).offer.length === 0, "nur die Frage: nichts");

  console.log("== pageRanges");
  ok(W.pageRanges([9]) === "Seite 9" && W.pageRanges([9], true) === "auf Seite 9", "eine Seite", W.pageRanges([9]));
  ok(W.pageRanges([3, 5]) === "die Seiten 3 und 5" && W.pageRanges([4, 3]) === "die Seiten 3 und 4", "zwei Seiten", W.pageRanges([4, 3]));
  ok(W.pageRanges([1, 2, 3, 4, 9, 20, 21, 22, 23]) === "die Seiten 1 bis 4, 9 und 20 bis 23", "Bereiche ab drei am Stück", W.pageRanges([1, 2, 3, 4, 9, 20, 21, 22, 23]));
  ok(W.pageRanges([1, 2, 3, 4, 9, 20, 21, 22, 23], true) === "auf den Seiten 1 bis 4, 9 und 20 bis 23", "Dativ", W.pageRanges([1, 2, 3, 4, 9, 20, 21, 22, 23], true));
  ok(W.pageRanges([7, 8, 9]) === "die Seiten 7 bis 9" && W.pageRanges([7, 8, 10, 11]) === "die Seiten 7, 8, 10 und 11", "drei am Stück; zweimal zwei einzeln", W.pageRanges([7, 8, 10, 11]));
  ok(W.pageRanges([5, 5, 6]) === "die Seiten 5 und 6" && W.pageRanges([]) === "", "doppelte nur einmal, leer");
  ok(W.pageRangesShort([1, 2, 3, 4, 9, 20, 21, 22, 23]) === "1–4, 9, 20–23" && W.pageRangesShort([61]) === "61", "kurz fürs Protokoll", W.pageRangesShort([1, 2, 3, 4, 9, 20, 21, 22, 23]));

  console.log("== jpegInfo");
  ok(W.jpegInfo(Buffer.from([1, 2, 3])) === null && W.jpegInfo(Buffer.alloc(0)) === null && W.jpegInfo("x") === null, "kein JPEG: null");
  const sof = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0x00, 0x00, 0xff, 0xff, 0xc0, 0x00, 0x11, 0x08, 0x02, 0x58, 0x03, 0x20, 0x03]);
  ok(same(W.jpegInfo(sof), { w: 800, h: 600, comps: 3 }), "SOF0 nach APP0 (mit Füllbyte)", W.jpegInfo(sof));
  ok(W.jpegInfo(sof.subarray(0, 15)) === null, "abgeschnitten: null");
  ok(W.jpegInfo(Buffer.from([0xff, 0xd8, 0xff, 0xda, 0x00, 0x04, 0, 0])) === null, "Scan vor SOF: null");
}

// ---------- PDF einer Seite ----------

function pageTests() {
  console.log("== pagePDF");
  if (!tools) { console.log("  skip  pagePDF (pdfinfo/pdftoppm fehlen)"); return; }
  const frame = { y: top(2), h: A4H };
  const Y = (y) => frame.y + y; // Seitenpunkte relativ zur Seite → absolut
  const strokes = [
    wire({ x: 100, y: Y(300), len: 300, w: 6, c: [1, 0, 0, 1], n: 12 }), // rot, dick
    wire({ x: 100, y: Y(400), len: 300, w: 8, c: [0, 0, 1, 0.5], n: 12 }), // blau, halb durchsichtig
    wire({ x: 100, y: Y(500), len: 300, w: 6, c: [0, 0, 0, 1], n: 12 }), // schwarz …
    wire({ x: 250, y: Y(470), dy: 60, len: 0.001, w: 16, c: [1, 1, 0, 1], ink: "com.apple.ink.marker", n: 6 }), // … darüber gelber Textmarker
    wire({ x: 600, y: Y(700), w: 10, n: 1, c: [0, 0.5, 0, 1] }), // ein Punkt
    wire({ x: 100, y: Y(800), len: 200, w: 2, ink: "(evil) Tj (", c: [0, 0, 0, 1], extra: { label: "BOESE" } }),
  ].map(W.compactStroke);
  const pdf = W.pagePDF({ frame, strokes, label: "Seite 3" });
  const info = pdfinfo(pdf, "page");
  ok(/Pages:\s+1\n/.test(info) && /Page size:\s+1200 x 1741 pts/.test(info), "pdfinfo: 1 Seite, 1200 × (1697 + 44)", info.match(/Page size.*$/m)?.[0]);
  ok(xrefOK(pdf), "Querverweise und Längen stimmen");
  try {
    const out = execFileSync("python3", ["-I", "-c", "import sys, pypdf; r = pypdf.PdfReader(sys.argv[1], strict=True); p = r.pages[0]; print(len(r.pages), p.mediabox.width, p.mediabox.height, len(p.get_contents().get_data()) > 0)", path.join(TMP, "page.pdf")], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    ok(out === "1 1200 1741 True", "pypdf (strict) liest es", out);
  } catch { console.log("  skip  pypdf nicht da"); }
  const content = contentOf(pdf);
  ok(/\/G\d gs/.test(content) && pdf.includes("/CA 0.5 /ca 0.5") && pdf.includes("/BM /Multiply"), "Deckkraft und Textmarker über ExtGState (CA/ca, Multiply)");
  ok(/ c\n/.test(content) && /1 J 1 j/.test(content), "Kurven (c), runde Enden und Ecken");
  ok(!content.includes("evil") && !pdf.includes("evil") && !pdf.includes("BOESE"), "kein Text aus den Strichen im PDF");
  const r = raster(pdf, "page");
  const s = 1200 / 768;
  const at = (x, y) => r.px(x * s, BAND + y * s); // Seitenpunkte → Pixel
  ok(r.w === 1200 && r.h === 1741, "Rastergröße 1200 × 1741", [r.w, r.h]);
  const band = r.px(600, 5);
  ok(band.every((v) => Math.abs(v - 230) <= 3), "Streifen oben hellgrau (0,9)", band);
  ok(r.darkest(16, 8, 110, 30) < 100, "„Seite 3“ im Streifen", r.darkest(16, 8, 110, 30));
  const red = at(250, 300);
  ok(red[0] > 200 && red[1] < 60 && red[2] < 60, "roter Strich", red);
  const blue = at(150, 400);
  ok(blue[2] > 200 && blue[0] > 100 && blue[0] < 160 && blue[1] > 100 && blue[1] < 160, "blau mit Deckkraft 0,5 über Weiß: hellblau", blue);
  const underMarker = at(250, 500), marker = at(250, 480);
  ok(underMarker.every((v) => v < 60), "Textmarker über Schwarz: bleibt schwarz (Multiplizieren)", underMarker);
  ok(marker[0] > 200 && marker[1] > 200 && marker[2] < 60, "Textmarker über Weiß: gelb", marker);
  const dot = at(600, 700);
  ok(dot[1] > 90 && dot[0] < 40 && dot[2] < 40, "einzelner Punkt als gefüllter Kreis", dot);
  const cell = at(GRID * 3 + GRID / 2, GRID * 2 + GRID / 2);
  ok(cell.every((v) => v === 255), "Karo innen weiß", cell);
  let line = 255;
  for (let dy = -1.5; dy <= 1.5; dy += 0.5) line = Math.min(line, at(GRID * 3 + GRID / 2, GRID * 2 + dy)[0]);
  ok(line >= 185 && line <= 240, "Karolinie grau (0,82, mindestens 1 Punkt breit)", line);
  // Hintergrund: ein JPEG genau in der Größe der Seite, unverändert eingebettet
  const src = makePDF([{ size: [595, 842] }]);
  const g = W.pageGeometry(768 * 842 / 595);
  const jpeg = jpegOf(src, 0, g.PW, g.PH);
  ok(same(W.jpegInfo(jpeg), { w: g.PW, h: g.PH, comps: 3 }), "jpegInfo eines echten JPEGs", [W.jpegInfo(jpeg), g]);
  const pframe = { y: 6, h: 768 * 842 / 595 };
  const withBg = W.pagePDF({ frame: pframe, strokes: [W.compactStroke(wire({ x: 300, y: 6 + 541, len: 0.001, dy: 40, w: 20, c: [1, 1, 0, 1], ink: "com.apple.ink.marker", n: 4 }))], label: "Seite 1", jpeg });
  ok(withBg.includes(jpeg) && withBg.includes("/Filter /DCTDecode") && xrefOK(withBg), "JPEG unverändert eingebettet (DCTDecode), Querverweise stimmen");
  const rb = raster(withBg, "bg");
  const bgBlue = rb.px(40, BAND + 40), bar = rb.px(300 * g.s, BAND + (pframe.h / 2) * g.s), plainBar = rb.px(450 * g.s, BAND + (pframe.h / 2) * g.s);
  ok(rb.w === 1200 && rb.h === g.PH + BAND && bgBlue[2] > 200 && bgBlue[0] < 60, "Hintergrund sichtbar (blaues Rechteck oben links)", [rb.w, rb.h, bgBlue]);
  ok(bar.every((v) => v < 70) && plainBar.every((v) => v < 70), "gedruckter Balken unter dem Textmarker bleibt dunkel", [bar, plainBar]);
  const land = W.pagePDF({ frame: { y: 6, h: 768 * 595 / 842 }, strokes: [], label: "Seite 2" });
  ok(/Page size:\s+1600 x 1175 pts/.test(pdfinfo(land, "land")), "Querformat 1600 breit", pdfinfo(land, "land").match(/Page size.*$/m)?.[0]);
  let threw = false;
  try { W.pagePDF({ frame, strokes: [], label: "x", jpeg: Buffer.from("kein jpeg") }); } catch { threw = true; }
  ok(threw, "kein brauchbares JPEG: Fehler statt leerer Seite");
  ok(contentOf(W.pagePDF({ frame, strokes: [], label: "Seite (1) \\ ä" })).includes("(Seite \\(1\\) \\\\ ?) Tj"), "Beschriftung maskiert");
}

// ---------- Mit Zustand ----------

const nb = (n) => `NB${String(n).padStart(4, "0")}-AAAA-BBBB`;

async function stateTests() {
  console.log("== Notizbuch: Angebot, Dateien, Spiegel");
  let h = harness();
  let doc = nb(1);
  // Seiten 0, 1, 3, 6 beschrieben (6 über pageCount 2 hinaus), Frage auf Seite 1
  h.srv.add(doc, "a0", wire({ x: 50, y: top(0) + 100 }));
  h.srv.add(doc, "a1", wire({ x: 60, y: top(1) + 200, nine: true }));
  h.srv.add(doc, "a3", wire({ x: 70, y: top(3) + 300 }));
  h.srv.add(doc, "a3b", wire({ x: 80, y: top(3) + 500, c: [1, 0, 0, 1] }));
  h.srv.add(doc, "a6", wire({ x: 90, y: top(6) + 50 }));
  h.srv.add(doc, "gone", wire({ x: 99, y: top(5) + 50 }));
  h.srv.remove(doc, "gone");
  let { r, qdir } = await ask(h, doc, 1);
  ok(r.more && same(r.more.pages, [1, 4, 7]) && same(r.more.written, [1, 4, 7]) && same(r.more.notReady, []) && same(r.more.over, []), "angeboten: 1, 4, 7 (ohne Frage, ohne gelöschte Seite 6)", r);
  ok(r.more?.movingFrom === null && r.more.highest === 7 && r.more.drawn === 3, "highest 7, 3 neu gezeichnet", r.more);
  const out = path.join(qdir, "weitere");
  ok(same(ls(out), ["seite-1.pdf", "seite-4.pdf", "seite-7.pdf"]), "Dateien seite-<N>.pdf", ls(out));
  const handed = ls(out).map((f) => fs.lstatSync(path.join(out, f)));
  ok(handed.every((st) => st.isFile() && !st.isSymbolicLink() && st.nlink === 1), "übergebene Dateien: echte Dateien, nlink 1, keine Verweise", handed.map((st) => [st.nlink, st.isSymbolicLink()]));
  ok(Object.keys(r.more.files).join() === "1,4,7" && r.more.files[4].bytes === fs.statSync(path.join(out, "seite-4.pdf")).size && /^[0-9a-f]{40}$/.test(r.more.files[4].key), "files: Bytes und Schlüssel je Seite", r.more.files);
  const cache = cacheFiles(h, doc);
  ok(cache.length === 3 && cache.every((f) => fs.statSync(path.join(h.HOME, "seitenbilder", doc, f)).nlink === 1), "Zwischenspeicher: 3 Seiten, nlink 1 (Kopie, kein harter Verweis)", cache);
  if (!tools) console.log("  skip  seite-4.pdf: Größe und Tinte (pdfinfo/pdftoppm fehlen)");
  else ok(/Page size:\s+1200 x 1741 pts/.test(pdfinfo(fs.readFileSync(path.join(out, "seite-4.pdf")), "s4")) && r4dark(fs.readFileSync(path.join(out, "seite-4.pdf"))), "seite-4.pdf: Größe und Tinte an der richtigen Stelle");
  let sd = stand(h, doc);
  ok(sd.cursor === 7 && sd.top === 7 && sd.complete === true, "stand.json: cursor = top, fertig", sd);
  const lines = fs.readFileSync(path.join(h.HOME, "spiegel", doc, "striche.ndjson"), "utf8").trim().split("\n").map((l) => JSON.parse(l));
  ok(lines.length === 6 && lines.at(-1)[1] === "gone" && lines.at(-1)[2] === null && lines[0][2].k === "com.apple.ink.pen" && !JSON.stringify(lines).includes("pk"), "striche.ndjson: [seq, id, kurz | null], ohne pk", lines.at(-1));
  ok(h.srv.calls.length === 1 && /\/api\/doc\/NB0001-AAAA-BBBB\/strokes\?since=0&limit=500&lite=1$/.test(h.srv.calls[0].p), "ein Abruf, since=0, limit=500, lite=1", h.srv.calls);
  ok(fs.existsSync(path.join(h.HOME, "hintergrund.js")) === false && h.osaCalls.length === 0, "Notizbuch: kein osascript");

  console.log("== Nachholen: ein Abruf, geänderte Seite neu, unveränderte bleiben");
  const keys1 = r.more.files;
  h.srv.add(doc, "a3c", wire({ x: 300, y: top(3) + 700 }));
  ({ r } = await ask(h, doc, 1));
  ok(h.srv.calls.length === 2 && h.srv.calls[1].p.includes("since=7&"), "ein Abruf seit dem letzten Stand", h.srv.calls.map((c) => c.p));
  ok(r.more?.drawn === 1 && r.more.files[1].key === keys1[1].key && r.more.files[7].key === keys1[7].key && r.more.files[4].key !== keys1[4].key, "nur die geänderte Seite neu gezeichnet", r.more);
  ({ r } = await ask(h, doc, 1));
  ok(r.more?.drawn === 0 && h.srv.calls.length === 3, "nichts geändert: nichts gezeichnet, ein Abruf");
  h.srv.remove(doc, "a6");
  ({ r } = await ask(h, doc, 1));
  ok(r.more && same(r.more.pages, [1, 4]) && r.more.highest === 4, "Strich gelöscht: Seite 7 fällt weg", r.more);

  console.log("== Seiten um die Frage (span)");
  ({ r } = await ask(h, doc, 1, { files: { span: [1, 4], context: [1, 4], contextFile: "fragen/x/nachbarseiten.pdf" } }));
  ok(r.more === undefined && same(r, {}), "App hat 1–4 gezeigt, sonst nichts beschrieben: {}", r);
  h.srv.add(doc, "a9", wire({ x: 91, y: top(9) + 50 }));
  ({ r } = await ask(h, doc, 1, { files: { span: [1, 4], context: [1, 4], contextFile: "fragen/x/nachbarseiten.pdf" } }));
  ok(r.more && same(r.more.pages, [10]) && same(r.more.written, [10]), "nur Seite 10 außerhalb des Bereichs", r);
  ({ r } = await ask(h, doc, 1, { files: { span: [1, 4], context: [] } }));
  ok(r.more && same(r.more.pages, [1, 4, 10]), "App sagt: nichts beschrieben, aber der Spiegel sieht 1 und 4: der Helfer bietet sie an", r.more);
  ({ r } = await ask(h, doc, 1, { files: { contextFailed: true } }));
  ok(r.more && same(r.more.pages, [1, 4, 10]), "Nachbarseiten nicht angekommen: der Helfer bietet sie an", r.more);
  ({ r } = await ask(h, doc, 1, { files: { span: [2, 2] } }));
  ok(r.more && same(r.more.pages, [1, 4, 10]), "Bereich nur die Frage", r.more);

  console.log("== nichts weiter beschrieben, Bedingungen");
  const lone = nb(2);
  h.srv.add(lone, "l1", wire({ x: 50, y: top(0) + 100 }));
  ({ r, qdir } = await ask(h, lone, 0));
  ok(same(r, {}) && !fs.existsSync(path.join(qdir, "weitere")), "nur die Seite der Frage beschrieben: {} und kein Ordner", r);
  h.cfg.morePages = { quick: 0, thorough: 20 };
  const before = h.srv.calls.length;
  ({ r } = await ask(h, doc, 1));
  ok(same(r, { moreOff: "aus" }) && h.srv.calls.length === before, "morePages quick 0: aus, kein Abruf", r);
  ({ r } = await ask(h, doc, 1, { effort: "thorough" }));
  ok(r.more?.pages.length === 3, "gründlich (20): an", r);
  h.cfg.morePages = undefined;
  ({ r } = await ask(h, doc, -1));
  ok(same(r, { moreOff: "Seite der Frage gelöscht" }), "Seite der Frage gelöscht (−1)", r);
  ({ r } = await ask(h, doc, 1, { files: { pdf: "dokument.pdf", pdfOld: true }, docExtra: { kind: "pdf", hasPDF: true } }));
  ok(same(r, { moreOff: "PDF zu alt" }), "pdfOld: aus", r);
  h.srv.meta(doc, { pagesVersion: 1763900000000 });
  const n0 = h.srv.calls.length;
  ({ r } = await ask(h, doc, 1, { pv: 1763800000000 }));
  ok(same(r, { moreOff: "Seitenstand anders" }) && h.srv.calls.length === n0 + 1, "Seitenstand der Frage ≠ Server: aus (nach einem Abruf)", r);
  ({ r } = await ask(h, doc, 1, { pv: 1763900000000 }));
  ok(r.more?.pages.length === 3, "gleicher Seitenstand: an", r);
  ({ r } = await ask(h, "../x", 1));
  ok(same(r, { moreOff: "Kennung ungültig" }), "Dokumentkennung ungültig", r);
  // Am Mac selbst klemmt es: geht weiter
  const qfile = path.join(h.HOME, "chats", doc, "fragen", "datei");
  fs.writeFileSync(qfile, "x");
  let err = null;
  try { await h.w.prepare({ id: "q", doc: { id: doc, kind: "notebook" }, anchor: { page: 1 }, pv: 1763900000000, effort: "quick" }, {}, { qdir: qfile, dir: path.join(h.HOME, "chats", doc), deadline: h.clock.t + 15000 }); } catch (e) { err = e; }
  ok(err?.code === "ENOTDIR", "Fehler am Mac (ENOTDIR) geht an den Helfer", err?.code);
  h.srv.mode = "ENOSPC";
  err = null;
  try { await ask(h, doc, 1, { pv: 1763900000000 }); } catch (e) { err = e; }
  ok(err?.code === "ENOSPC", "ENOSPC geht an den Helfer", err?.code);
  h.srv.mode = null;

  console.log("== Server-Fehler, Route fehlt (10 Minuten Pause, nur im Speicher)");
  h = harness();
  doc = nb(3);
  h.srv.add(doc, "x1", wire({ x: 50, y: top(0) + 100 }));
  h.srv.add(doc, "x2", wire({ x: 50, y: top(2) + 100 }));
  for (const [mode, why] of [["500", "Server-Fehler (HTTP 500)"], ["net", "Server nicht erreichbar"], ["404code", "Server-Fehler (HTTP 404)"]]) {
    h.srv.mode = mode;
    ({ r } = await ask(h, doc, 0));
    ok(same(r, { moreOff: why }) && !h.state.weitere?.offUntil, `${mode}: ${why}, keine Pause`, r);
  }
  h.srv.mode = "404";
  ({ r } = await ask(h, doc, 0));
  ok(same(r, { moreOff: "Server ohne Route" }) && !JSON.stringify(h.state).includes("offUntil"), "404 ohne code: Server ohne Route, Pause nicht im gespeicherten Zustand", h.state);
  h.srv.mode = null;
  let n = h.srv.calls.length;
  h.clock.t += 9 * MIN;
  ({ r } = await ask(h, doc, 0));
  ok(same(r, { moreOff: "Server ohne Route" }) && h.srv.calls.length === n, "9 Minuten später: kein Abruf", h.srv.calls.length - n);
  h.clock.t += MIN;
  ({ r } = await ask(h, doc, 0));
  ok(r.more && same(r.more.pages, [3]), "nach 10 Minuten: wieder an", r);
  h.srv.mode = "404";
  ({ r } = await ask(h, doc, 0));
  h.srv.mode = null;
  ok(same(r, { moreOff: "Server ohne Route" }) && h.logs.filter((l) => l.includes("Server-Update nötig")).length === 1, "noch einmal ohne Route: einmal im Protokoll", h.logs);
  // Server-Update, dann der Helfer neu gestartet (Einrichten): fragt gleich wieder
  const restarted = harness({ home: h.HOME, srv: h.srv, clock: h.clock });
  n = h.srv.calls.length;
  ({ r } = await ask(restarted, doc, 0));
  ok(r.more && same(r.more.pages, [3]) && h.srv.calls.length === n + 1, "nach einem Neustart: gleich wieder gefragt", r);

  console.log("== Zeilen je Tag (UTC)");
  h = harness({ cfg: { mirrorRowsPerDay: 1200 } });
  doc = nb(4);
  for (let i = 0; i < 2500; i++) h.srv.add(doc, `r${i}`, wire({ x: 20 + (i % 50) * 14, y: top(Math.floor(i / 250)) + 40 + (i % 250) * 4, len: 10, n: 3 }));
  ({ r } = await ask(h, doc, 0, { deadline: h.clock.t + 600000 }));
  ok(same(r, { moreOff: "Tageslimit erreicht" }) && h.state.weitere.rows === 1200 && h.srv.calls.length === 3, "nach 504 + 504 + 192 Zeilen: Tageslimit", [r, h.state.weitere, h.srv.calls.map((c) => c.p)]);
  ok(h.srv.calls[2].p.includes("limit=188"), "der letzte Abruf nur so groß, wie noch erlaubt", h.srv.calls[2].p);
  n = h.srv.calls.length;
  ({ r } = await ask(h, doc, 0));
  ok(same(r, { moreOff: "Tageslimit erreicht" }) && h.srv.calls.length === n, "gleicher Tag: kein Abruf", r);
  ok(h.logs.filter((l) => l.includes("1200 gelesene Zeilen")).length === 1, "einmal im Protokoll", h.logs);
  h.cfg.mirrorRowsPerDay = 250000;
  h.clock.t += DAY;
  ({ r } = await ask(h, doc, 0, { deadline: h.clock.t + 600000 }));
  ok(r.more?.pages.length === 9 && h.state.weitere.rows === 1312 + 12, "nächster Tag: Rest geholt, neu gezählt", [r.more?.pages, h.state.weitere]);
  // Lange Striche: Die Zeichengrenze beendet das Stück vor limit, der Server liest dann eine Zeile mehr
  {
    const hc = harness();
    const dc = nb(10);
    for (let i = 0; i < 5; i++) hc.srv.add(dc, `lang${i}`, wire({ x: 50 + i * 30, y: top(i) + 100, extra: { pad: "x".repeat(450000) } }));
    ({ r } = await ask(hc, dc, 0));
    const got = hc.srv.calls.map((c) => c.p);
    ok(r.more && same(r.more.pages, [2, 3, 4, 5]) && got.length === 3 && hc.state.weitere.rows === (2 + 5) + (2 + 5) + (1 + 4), "an der Zeichengrenze (2, 2, dann 1 Strich): je Abruf eine Zeile mehr gezählt (19)", [hc.state.weitere, got]);
  }

  console.log("== Neu am Server: top < cursor, low > cursor, gelöscht");
  const cur = stand(h, doc).cursor;
  h.srv.wipe(doc);
  ({ r } = await ask(h, doc, 0));
  ok(same(r, {}) && stand(h, doc).cursor === 0 && h.logs.some((l) => l.includes("Spiegel von vorn")), "Striche am Server weg (top < cursor): Spiegel von vorn", [r, cur]);
  h.srv.add(doc, "n1", wire({ x: 50, y: top(0) + 100 }));
  h.srv.add(doc, "n2", wire({ x: 50, y: top(1) + 100 }));
  ({ r } = await ask(h, doc, 0));
  ok(r.more && same(r.more.pages, [2]) && fs.readFileSync(path.join(h.HOME, "spiegel", doc, "striche.ndjson"), "utf8").trim().split("\n").length === 2, "danach nur die neuen Striche", r);
  // Gelöscht und von einem anderen Gerät zurückgeholt, das alle seine Striche unter ihren IDs neu hinaufschickt: Was
  // es nicht hat (n3), kommt nicht wieder, auch kein Grabstein. top liegt dann über dem Stand, aber auch low
  h.srv.add(doc, "n3", wire({ x: 50, y: top(3) + 100 }));
  ({ r } = await ask(h, doc, 0));
  ok(r.more && same(r.more.pages, [2, 4]), "n3 auf Seite 4 dazu", r.more);
  const c1 = stand(h, doc).cursor, fromScratch = h.logs.filter((l) => l.includes("Spiegel von vorn")).length;
  h.srv.wipe(doc);
  h.srv.add(doc, "n1", wire({ x: 50, y: top(0) + 100 }));
  h.srv.add(doc, "n2", wire({ x: 50, y: top(1) + 100 }));
  let nc = h.srv.calls.length;
  ({ r } = await ask(h, doc, 0));
  ok(r.more && same(r.more.pages, [2]) && h.logs.filter((l) => l.includes("Spiegel von vorn")).length === fromScratch + 1, "zurückgeholt ohne n3 (low > Stand): Spiegel von vorn, Seite 4 nicht mehr angeboten", [r.more, c1]);
  ok(h.srv.calls.length === nc + 1 && h.srv.calls.at(-1).p.includes(`since=${c1}&`) && !fs.readFileSync(path.join(h.HOME, "spiegel", doc, "striche.ndjson"), "utf8").includes('"n3"'), "alle Zeilen neuer als der Stand: dieselbe Antwort genügt (ein Abruf), n3 nicht mehr im Spiegel", h.srv.calls.slice(nc).map((c) => c.p));
  nc = h.srv.calls.length;
  ({ r } = await ask(h, doc, 0));
  ok(r.more && same(r.more.pages, [2]) && h.srv.calls.length === nc + 1 && h.logs.filter((l) => l.includes("Spiegel von vorn")).length === fromScratch + 1, "danach wieder nur nachholen", r.more);
  h.srv.meta(doc, { deleted: true });
  ({ r } = await ask(h, doc, 0));
  ok(same(r, { moreOff: "Dokument gelöscht" }) && !fs.existsSync(path.join(h.HOME, "spiegel", doc)) && !fs.existsSync(path.join(h.HOME, "seitenbilder", doc)), "gelöscht: Spiegel und Seiten weg", r);

  console.log("== Frist, Abbruch, warm()");
  h = harness();
  doc = nb(5);
  for (let p = 0; p < 10; p++) h.srv.add(doc, `f${p}`, wire({ x: 30 + p * 9, y: top(p) + 200 }));
  // Jede Prüfung auf Abbruch rückt die Uhr eine Sekunde vor: Nach etwa zwei Seiten ist die Frist um
  let t0 = h.clock.t;
  ({ r } = await ask(h, doc, 4, { deadline: t0 + 3500, isCancelled: () => { h.clock.t += 1000; return false; } }));
  const offer = W.chooseMore({ q: 4, written: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9] }).offer.map((i) => i + 1);
  ok(r.more && r.more.pages.length >= 1 && r.more.notReady.length >= 1 && same([...r.more.pages, ...r.more.notReady].sort((a, b) => a - b), [...offer].sort((a, b) => a - b)), "Frist um: gezeichnet + nicht bereit = angeboten", r.more);
  ok(r.more && r.more.pages.every((p) => offer.indexOf(p) < Math.min(...r.more.notReady.map((x) => offer.indexOf(x)))), "die nächsten zuerst gezeichnet", [r.more?.pages, r.more?.notReady]);
  ok(r.more && same(r.more.written, offer.slice().sort((a, b) => a - b)), "written: alle angebotenen", r.more?.written);
  ({ r, qdir } = await ask(h, doc, 4, { isCancelled: () => cacheFiles(h, doc).length >= 4 }));
  ok(same(r, { moreOff: "abgebrochen" }) && !fs.existsSync(path.join(qdir, "weitere")), "abgebrochen: moreOff, kein Ordner", r);
  // Spiegel nicht fertig bis zur Frist: warm() holt den Rest und zeichnet vor
  h = harness();
  doc = nb(6);
  for (let i = 0; i < 1300; i++) h.srv.add(doc, `w${i}`, wire({ x: 20 + (i % 40) * 17, y: top(Math.floor(i / 100)) + 40 + (i % 100) * 9, len: 12, n: 3 }));
  ({ r } = await ask(h, doc, 0, { deadline: h.clock.t - 1 }));
  ok(same(r, { moreOff: "Spiegel nicht fertig" }) && h.srv.calls.length === 1 && stand(h, doc).complete === false, "Frist schon um: ein Abruf, dann Spiegel nicht fertig", [r, h.srv.calls.length]);
  await h.w.warm(() => true);
  ok(h.srv.calls.length === 1, "warm() mit shouldStop: nichts");
  await h.w.warm(() => false);
  ok(stand(h, doc).complete === true && h.srv.calls.length === 3 && cacheFiles(h, doc).length === 12, "warm(): Spiegel fertig geholt, Seiten vorgezeichnet", [h.srv.calls.length, cacheFiles(h, doc).length]);
  ({ r } = await ask(h, doc, 0));
  ok(r.more?.drawn === 0 && r.more.pages.length === 12 && h.srv.calls.length === 4, "danach: ein Abruf, nichts mehr zu zeichnen", r.more);
  await h.w.warm(() => false);
  ok(h.srv.calls.length === 4, "warm() ohne offene Arbeit: kein Abruf");
  // Ein langsamer Abruf in warm(): Kommt etwas (Lernwort, Frage), bricht er gleich ab, nicht erst nach der Antwort
  h = harness();
  doc = nb(11);
  for (let i = 0; i < 1300; i++) h.srv.add(doc, `s${i}`, wire({ x: 20 + (i % 40) * 17, y: top(Math.floor(i / 100)) + 40 + (i % 100) * 9, len: 12, n: 3 }));
  ({ r } = await ask(h, doc, 0, { deadline: h.clock.t - 1 }));
  h.srv.delayMs = 3000;
  let stop = false;
  const ac = new AbortController();
  setTimeout(() => { stop = true; ac.abort(); }, 200);
  const tw = Date.now();
  await h.w.warm(() => stop, ac.signal);
  const tookW = Date.now() - tw;
  ok(tookW < 1500 && h.srv.calls.length === 2 && h.srv.calls[1].signal && stand(h, doc).complete === false, `Abruf in warm() abgebrochen: nach ${tookW} ms zurück (die Antwort käme nach 3 s)`, [tookW, h.srv.calls.length]);
  h.srv.delayMs = 0;
  await h.w.warm(() => false, new AbortController().signal);
  ok(stand(h, doc).complete === true && cacheFiles(h, doc).length === 12, "danach holt warm() den Rest und zeichnet vor", [stand(h, doc), cacheFiles(h, doc).length]);

  console.log("== Zwillinge nach einer Seitenänderung");
  h = harness();
  doc = nb(7);
  const pv = h.clock.t - 5 * MIN;
  h.srv.meta(doc, { pagesVersion: pv, pageCount: 7 });
  const put = (pi, shift, prefix) => [0, 1, 2].forEach((k) => h.srv.add(doc, `${prefix}${pi}-${k}`, wire({ x: 40 + pi * 13 + k * 101, y: top(pi) + 100 + k * 80 + shift, len: 50 + k * 7 + pi })));
  for (const pi of [0, 1, 2, 3, 4, 5]) put(pi, 0, "o");
  for (const pi of [3, 4, 5]) put(pi, A4H + GAP, "n"); // Seite 3 eingefügt: die Striche darunter neu, die alten noch da
  ({ r } = await ask(h, doc, 0));
  ok(r.more && r.more.movingFrom === 4 && same(r.more.pages, [2, 3]) && same(r.more.written, [2, 3]), "ab Seite 4 im Abgleich: nur 2 und 3", r.more);
  for (const pi of [3, 4, 5]) [0, 1, 2].forEach((k) => h.srv.remove(doc, `o${pi}-${k}`));
  ({ r } = await ask(h, doc, 0));
  ok(r.more && r.more.movingFrom === null && same(r.more.pages, [2, 3, 5, 6, 7]), "alte gelöscht: alles angeboten (4 ist die neue leere Seite)", r.more);
  const h2 = harness({ clock: { t: Date.now() } });
  h2.srv.meta(doc, { pagesVersion: h2.clock.t - 31 * MIN, pageCount: 7 });
  for (const pi of [0, 1, 2, 3, 4, 5]) [0, 1, 2].forEach((k) => h2.srv.add(doc, `o${pi}-${k}`, wire({ x: 40 + pi * 13 + k * 101, y: top(pi) + 100 + k * 80, len: 50 + k * 7 + pi })));
  for (const pi of [3, 4, 5]) [0, 1, 2].forEach((k) => h2.srv.add(doc, `n${pi}-${k}`, wire({ x: 40 + pi * 13 + k * 101, y: top(pi) + 100 + k * 80 + A4H + GAP, len: 50 + k * 7 + pi })));
  ({ r } = await ask(h2, doc, 0));
  ok(r.more && r.more.movingFrom === null && same(r.more.pages, [2, 3, 4, 5, 6, 7]), "Seitenänderung vor über 30 Minuten: Kopien zählen nicht", r.more);

  console.log("== über 200 Seiten");
  h = harness();
  doc = nb(8);
  h.srv.meta(doc, { pageCount: 206 });
  for (let p = 0; p < 206; p++) h.srv.add(doc, `p${p}`, wire({ x: 100, y: top(p) + 300, len: 100, n: 2 }));
  ({ r } = await ask(h, doc, 0, { deadline: h.clock.t + 600000 }));
  ok(r.more && r.more.pages.length === 200 && r.more.pages[0] === 2 && r.more.pages.at(-1) === 201 && same(r.more.over, [202, 203, 204, 205, 206]) && r.more.written.length === 205, "200 nächste angeboten, 5 in over", [r.more?.pages.length, r.more?.over]);
  ok(ls(path.join(h.HOME, "chats", doc, "fragen", `ASK-${askNo}`, "weitere")).length === 200, "200 Dateien");

  console.log("== Spiegel: halbe letzte Zeile, Verdichten, wieder laden");
  h = harness();
  doc = nb(9);
  for (let i = 0; i < 40; i++) h.srv.add(doc, `c${i}`, wire({ x: 20 + i * 9, y: top(i % 4) + 100 + i, len: 30 }));
  ({ r } = await ask(h, doc, 0));
  const file = path.join(h.HOME, "spiegel", doc, "striche.ndjson");
  for (let i = 0; i < 30; i++) h.srv.remove(doc, `c${i}`);
  ({ r } = await ask(h, doc, 0));
  const kept = fs.readFileSync(file, "utf8").trim().split("\n");
  ok(kept.length === 10 && kept.every((l) => JSON.parse(l)[2] !== null), "mehr tote als lebende Zeilen: neu geschrieben (nur die 10 lebenden)", kept.length);
  const cursorBefore = stand(h, doc).cursor;
  fs.appendFileSync(file, '[999,"halb",{"k":"com.apple');
  h.srv.add(doc, "c40", wire({ x: 500, y: top(5) + 100 }));
  const fresh = harness({ home: h.HOME, srv: h.srv, clock: h.clock });
  ({ r } = await ask(fresh, doc, 0));
  ok(r.more && r.more.pages.includes(6) && fs.readFileSync(file, "utf8").endsWith("\n") && !fs.readFileSync(file, "utf8").includes("halb"), "neu gestartet: halbe Zeile weg, neue Striche da", r.more?.pages);
  ok(fresh.srv.calls.at(-1).p.includes(`since=${cursorBefore}&`), "holt ab dem gespeicherten Stand", [cursorBefore, fresh.srv.calls.at(-1).p]);
  // Spiegel fehlt, stand.json noch da: von vorn
  fs.rmSync(file);
  const again = harness({ home: h.HOME, srv: h.srv, clock: h.clock });
  ({ r } = await ask(again, doc, 0));
  ok(r.more && again.srv.calls.at(-1).p.includes("since=0&"), "Striche-Datei fehlt: von vorn", again.srv.calls.at(-1).p);
  // Strom weg: stand.json ist schon neu, das zuletzt Angehängte aber nicht auf der Platte (Datei kürzer als in stand.json)
  h.srv.add(doc, "c41", wire({ x: 500, y: top(7) + 100 }));
  ({ r } = await ask(again, doc, 0));
  ok(r.more && r.more.pages.includes(8) && Number.isInteger(stand(h, doc).bytes) && stand(h, doc).bytes === fs.statSync(file).size && stand(h, doc).lines > 0, "stand.json merkt sich Größe und Zeilen der Striche-Datei", stand(h, doc));
  const whole = fs.readFileSync(file, "utf8");
  fs.writeFileSync(file, whole.slice(0, whole.lastIndexOf("\n", whole.length - 2) + 1));
  const cut = harness({ home: h.HOME, srv: h.srv, clock: h.clock });
  ({ r } = await ask(cut, doc, 0));
  ok(r.more && r.more.pages.includes(8) && cut.srv.calls.at(-1).p.includes("since=0&") && cut.logs.some((l) => l.includes("auf der Platte unvollständig")), "Datei kürzer als in stand.json: von vorn, Seite 8 wieder da", [r.more?.pages, cut.srv.calls.at(-1).p, cut.logs]);
}

/// Tinte von seite-4.pdf (Seite 3 ab 0: Striche bei 300 und 500 Seitenpunkten unter der Oberkante)
function r4dark(pdf) {
  const r = raster(pdf, "s4r");
  const s = 1200 / 768;
  return r.darkest(Math.round(80 * s), Math.round(BAND + 295 * s), Math.round(260 * s), Math.round(BAND + 305 * s)) < 100 &&
    r.darkest(Math.round(500 * s), Math.round(BAND + 290 * s), Math.round(700 * s), Math.round(BAND + 310 * s)) > 600;
}

async function pdfTests() {
  console.log("== PDF: Prüfung, Höhen, Hintergrund");
  if (!tools) { console.log("  skip  PDF (pdfinfo/pdftoppm fehlen)"); return; }
  let h = harness();
  const doc = "PDF00001-AAAA";
  const dir = path.join(h.HOME, "chats", doc);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "dokument.pdf"), makePDF([{ size: [595, 842] }, { size: [842, 595] }, { size: [595, 842] }, { size: [595, 842], rotate: 90 }]));
  const heights = [768 * 842 / 595, 768 * 595 / 842, 768 * 842 / 595, 768 * 595 / 842];
  const frames = W.pdfFrames(heights);
  h.state.docs[doc] = { pdfVersion: 7 };
  h.srv.meta(doc, { kind: "pdf", pageCount: 4, pdfVersion: 7 });
  h.srv.add(doc, "p0", wire({ x: 100, y: frames[0].y + 300 }));
  h.srv.add(doc, "p2", wire({ x: 100, y: frames[2].y + 300, w: 10, c: [1, 1, 0, 1], ink: "com.apple.ink.marker", len: 400 }));
  h.srv.add(doc, "p3", wire({ x: 100, y: frames[3].y + 100 }));
  h.srv.add(doc, "below", wire({ x: 100, y: frames[3].y + frames[3].h + 400 })); // unter der letzten Seite
  const pdfDoc = { kind: "pdf", hasPDF: true, pdfVersion: 7 };
  let { r, qdir } = await ask(h, doc, 1, { files: { pdf: "dokument.pdf" }, docExtra: pdfDoc });
  ok(h.logs.some((l) => l.includes("PDF-Hintergrund geprüft")), "Prüfung von hintergrund.js bestanden", h.logs);
  ok(fs.readFileSync(path.join(h.HOME, "hintergrund.js"), "utf8") === W.BG_SCRIPT, "hintergrund.js im Ordner des Helfers");
  ok(r.more && same(r.more.pages, [1, 3, 4]) && r.more.highest === 4, "Seiten 1, 3, 4 angeboten (Tinte unter der letzten Seite fällt weg)", r);
  const hj = JSON.parse(fs.readFileSync(path.join(h.HOME, "seitenbilder", doc, "v7", "hoehen.json"), "utf8"));
  ok(hj.heights.length === 4 && hj.heights.every((v, i) => near(v, heights[i], 0.01)) && hj.pages[3].rot === 90, "Höhen samt Querformat und Drehung (hoehen.json je PDF-Stand)", hj);
  const bg = (i) => path.join(h.HOME, "seitenbilder", doc, "v7", `bg-${i}.jpg`);
  ok(same(W.jpegInfo(fs.readFileSync(bg(0))), { w: 1200, h: 1698, comps: 3 }) && same(W.jpegInfo(fs.readFileSync(bg(3))), { w: 1600, h: 1131, comps: 3 }), "Hintergründe genau in der Seitengröße (hoch 1200 × 1698, gedreht quer 1600 × 1131)", [W.jpegInfo(fs.readFileSync(bg(0))), W.jpegInfo(fs.readFileSync(bg(3)))]);
  const s1 = fs.readFileSync(path.join(qdir, "weitere", "seite-1.pdf")), s4 = fs.readFileSync(path.join(qdir, "weitere", "seite-4.pdf"));
  ok(s1.includes(fs.readFileSync(bg(0))) && s4.includes(fs.readFileSync(bg(3))), "JPEG unverändert im PDF der Seite");
  ok(/Page size:\s+1600 x 1175 pts/.test(pdfinfo(s4, "pdf4")), "gedrehte Seite: Querformat 1600 × (1131 + 44)", pdfinfo(s4, "pdf4").match(/Page size.*$/m)?.[0]);
  const r1 = raster(s1, "pdf1");
  ok(r1.px(40, BAND + 40)[2] > 200 && r1.px(40, BAND + 40)[0] < 60, "PDF-Seite als Hintergrund (blaues Rechteck)", r1.px(40, BAND + 40));
  const r3 = raster(fs.readFileSync(path.join(qdir, "weitere", "seite-3.pdf")), "pdf3");
  const g3 = W.pageGeometry(heights[2]);
  const under = r3.px(384 * g3.s, BAND + (heights[2] / 2) * g3.s), mk = r3.px(300 * g3.s, BAND + 300 * g3.s);
  ok(mk[0] > 200 && mk[1] > 200 && mk[2] < 80, "Textmarker gelb", mk);
  ok(under.every((v) => v < 80), "gedruckter Balken bleibt sichtbar", under);
  let bgCalls = calls(h.FAKE).filter((c) => c.bg);
  ok(bgCalls.length === 5 && same(bgCalls.map((c) => c.bg.mode), ["hoehen", "bilder", "farben", "hoehen", "bilder"]) && bgCalls.every((c) => c.envKeys.length === 0), "Prüfung (hoehen, bilder, farben), dann hoehen und ein bilder für alle Seiten", bgCalls.map((c) => c.bg));
  ok(same(bgCalls[2]?.bg.specs, ["0:19:121", "0:69:56", "0:48:68", "1:13:57", "1:49:11", "1:48:34", "2:10:13", "2:55:49", "2:48:34", "3:64:66", "3:48:51"]), "farben: blau und rot, wo sie hingehören (auch gedreht und in der CropBox), Weiß in der Mitte", bgCalls[2]?.bg.specs);
  ok(same(bgCalls[4]?.bg.specs, ["0:1200:1698", "2:1200:1698", "3:1600:1131"]), "bilder: nur Seite, Breite, Höhe", bgCalls[4]?.bg.specs);
  ok(h.osaCalls.every((a) => a[0] === "-l" && a[1] === "JavaScript" && a[2] === path.join(h.HOME, "hintergrund.js") && a.slice(3).every((x) => /^(hoehen|bilder|farben|\d+:\d+:\d+)$/.test(x) || (x.startsWith(h.HOME) && !x.includes("chats/") || x === path.join(dir, "dokument.pdf")))), "osascript bekommt nur Pfade und Zahlen", h.osaCalls);
  ({ r } = await ask(h, doc, 1, { files: { pdf: "dokument.pdf" }, docExtra: pdfDoc }));
  ok(r.more?.drawn === 0 && calls(h.FAKE).filter((c) => c.bg).length === 5, "zweite Frage: Hintergründe, Höhen und Seiten aus dem Zwischenspeicher", r.more);
  h.srv.add(doc, "p0b", wire({ x: 300, y: frames[0].y + 600 }));
  ({ r } = await ask(h, doc, 1, { files: { pdf: "dokument.pdf" }, docExtra: pdfDoc }));
  ok(r.more?.drawn === 1 && calls(h.FAKE).filter((c) => c.bg).length === 5, "neuer Strich: Seite neu gezeichnet, Hintergrund bleibt", r.more);
  // Neues PDF (Stand 8): Höhen und Hintergründe neu, Stand 7 weg
  fs.writeFileSync(path.join(dir, "dokument.pdf"), makePDF([{ size: [595, 842] }, { size: [842, 595] }, { size: [842, 595] }, { size: [595, 842], rotate: 90 }]));
  h.state.docs[doc].pdfVersion = 9;
  h.srv.meta(doc, { pdfVersion: 8 });
  ({ r } = await ask(h, doc, 1, { files: { pdf: "dokument.pdf" }, docExtra: { ...pdfDoc, pdfVersion: 9 } }));
  ok(same(r, { moreOff: "PDF zu alt" }), "PDF im Chat-Ordner anders als am Server: aus", r);
  h.state.docs[doc].pdfVersion = 8;
  ({ r } = await ask(h, doc, 1, { files: { pdf: "dokument.pdf" }, docExtra: { ...pdfDoc, pdfVersion: 8 } }));
  ok(r.more && same(r.more.pages, [1, 3]) && !fs.existsSync(path.join(h.HOME, "seitenbilder", doc, "v7")) && fs.existsSync(path.join(h.HOME, "seitenbilder", doc, "v8", "bg-0.jpg")), "PDF-Stand 8: neue Höhen (Seite 3 jetzt quer, der Strich auf 4 liegt nun unter der letzten Seite), Stand 7 weg", r.more);
  ok(calls(h.FAKE).filter((c) => c.bg).length === 7, "dafür hoehen und bilder je einmal", calls(h.FAKE).filter((c) => c.bg).length);
  ({ r } = await ask(h, doc, 1, { docExtra: pdfDoc }));
  ok(same(r, { moreOff: "PDF fehlt" }), "PDF fehlt im Chat-Ordner: aus", r);

  console.log("== PDF: Prüfung scheitert (auch: richtige Größe, aber falsch gezeichnet), Notizbücher gehen trotzdem");
  for (const knob of [{ fail: true }, { wrongSize: true }, { blank: true }, { noRotate: true }, { noCrop: true }]) {
    h = harness();
    fs.writeFileSync(path.join(h.FAKE, "bg.json"), JSON.stringify(knob));
    const d2 = path.join(h.HOME, "chats", doc);
    fs.mkdirSync(d2, { recursive: true });
    fs.writeFileSync(path.join(d2, "dokument.pdf"), makePDF([{ size: [595, 842] }, { size: [595, 842] }]));
    h.state.docs[doc] = { pdfVersion: 7 };
    h.srv.meta(doc, { kind: "pdf", pageCount: 2, pdfVersion: 7 });
    h.srv.add(doc, "q0", wire({ x: 100, y: 300 }));
    ({ r } = await ask(h, doc, 1, { files: { pdf: "dokument.pdf" }, docExtra: pdfDoc }));
    ({ r } = await ask(h, doc, 1, { files: { pdf: "dokument.pdf" }, docExtra: pdfDoc }));
    ok(same(r, { moreOff: "PDF-Hintergrund geht nicht" }) && h.srv.calls.length === 0, `${Object.keys(knob)[0]}: PDFs aus, kein Abruf`, r);
    ok(h.logs.filter((l) => l.includes("PDF-Hintergrund geht nicht")).length === 1 && calls(h.FAKE).filter((c) => c.bg).length <= 3, "einmal geprüft, einmal im Protokoll", h.logs);
    if (knob.blank || knob.noRotate || knob.noCrop) ok(h.logs.some((l) => /PDF-Hintergrund geht nicht \(Bild \d falsch gezeichnet \((blau|rot) bei \d+, \d+: \d+, \d+, \d+\)\)/.test(l)), "im Protokoll: welches Bild, welche Farbe wo", h.logs);
    const nd = nb(20);
    h.srv.add(nd, "z0", wire({ x: 50, y: top(0) + 100 }));
    h.srv.add(nd, "z1", wire({ x: 50, y: top(2) + 100 }));
    ({ r } = await ask(h, nd, 0));
    ok(r.more && same(r.more.pages, [3]), "Notizbuch geht trotzdem", r);
  }
  // Ein Hintergrund scheitert: diese Seite nicht bereit (erst die Prüfung, dann scheitert Seite 3 des Dokuments)
  h = harness();
  const d3 = path.join(h.HOME, "chats", doc);
  fs.mkdirSync(d3, { recursive: true });
  fs.writeFileSync(path.join(d3, "dokument.pdf"), makePDF([{ size: [595, 842] }, { size: [595, 842] }, { size: [595, 842] }]));
  h.state.docs[doc] = { pdfVersion: 7 };
  h.srv.meta(doc, { kind: "pdf", pageCount: 3, pdfVersion: 7 });
  ({ r } = await ask(h, doc, 1, { files: { pdf: "dokument.pdf" }, docExtra: pdfDoc }));
  ok(same(r, {}) && h.logs.some((l) => l.includes("PDF-Hintergrund geprüft")), "leeres PDF-Dokument: geprüft, {}", r);
  fs.writeFileSync(path.join(h.FAKE, "bg.json"), JSON.stringify({ failPages: [2] }));
  const f3 = W.pdfFrames([768 * 842 / 595, 768 * 842 / 595, 768 * 842 / 595]);
  h.srv.add(doc, "k0", wire({ x: 100, y: f3[0].y + 300 }));
  h.srv.add(doc, "k2", wire({ x: 100, y: f3[2].y + 300 }));
  ({ r } = await ask(h, doc, 1, { files: { pdf: "dokument.pdf" }, docExtra: pdfDoc }));
  ok(r.more && same(r.more.pages, [1]) && same(r.more.notReady, [3]) && same(r.more.written, [1, 3]), "Hintergrund von Seite 3 scheitert: nicht bereit", r.more);
  ok(h.logs.filter((l) => l.includes("Hintergrund nicht gezeichnet")).length === 1, "im Protokoll", h.logs);
  // Nach bestandener Prüfung kommt ein Hintergrund in falscher Größe: Seite nicht bereit, nicht mit falschem Bild
  fs.writeFileSync(path.join(h.FAKE, "bg.json"), JSON.stringify({ wrongSize: true }));
  h.srv.add(doc, "k0b", wire({ x: 300, y: f3[0].y + 600 }));
  fs.rmSync(path.join(h.HOME, "seitenbilder", doc, "v7", "bg-0.jpg"));
  ({ r } = await ask(h, doc, 1, { files: { pdf: "dokument.pdf" }, docExtra: pdfDoc }));
  ok(r.more && same(r.more.pages, []) && same(r.more.notReady, [1, 3]) && !fs.existsSync(path.join(h.HOME, "seitenbilder", doc, "v7", "bg-0.jpg")), "Hintergrund in falscher Größe: verworfen, Seite nicht bereit", r.more);
  ok(h.logs.some((l) => l.includes("falsche Größe")), "im Protokoll", h.logs);
  // Ein beschädigter Hintergrund im Zwischenspeicher wird ersetzt
  fs.writeFileSync(path.join(h.FAKE, "bg.json"), "{}");
  fs.writeFileSync(path.join(h.HOME, "seitenbilder", doc, "v7", "bg-0.jpg"), jpegOf(makePDF([{ size: [595, 842] }]), 0, 300, 400));
  ({ r } = await ask(h, doc, 1, { files: { pdf: "dokument.pdf" }, docExtra: pdfDoc }));
  ok(r.more && same(r.more.pages, [1, 3]) && same(W.jpegInfo(fs.readFileSync(path.join(h.HOME, "seitenbilder", doc, "v7", "bg-0.jpg"))), { w: 1200, h: 1698, comps: 3 }), "Hintergrund in falscher Größe im Zwischenspeicher: neu gezeichnet (und Seite 3 jetzt auch)", r.more);

  console.log("== PDF: osascript hängt: höchstens bis zur Frist der Frage, und das schaltet PDFs nicht ab");
  h = harness();
  const d4 = path.join(h.HOME, "chats", doc);
  fs.mkdirSync(d4, { recursive: true });
  fs.writeFileSync(path.join(d4, "dokument.pdf"), makePDF([{ size: [595, 842] }, { size: [595, 842] }]));
  h.state.docs[doc] = { pdfVersion: 7 };
  h.srv.meta(doc, { kind: "pdf", pageCount: 2, pdfVersion: 7 });
  h.srv.add(doc, "h0", wire({ x: 100, y: W.pdfFrames([768 * 842 / 595])[0].y + 300 }));
  fs.writeFileSync(path.join(h.FAKE, "bg.json"), JSON.stringify({ delayMs: 5000 }));
  let t1 = Date.now();
  ({ r } = await ask(h, doc, 1, { files: { pdf: "dokument.pdf" }, docExtra: pdfDoc, deadline: h.clock.t + 1500 }));
  let took = Date.now() - t1;
  ok(same(r, { moreOff: "PDF-Hintergrund nicht rechtzeitig geprüft" }) && took < 4000 && h.srv.calls.length === 0, `Prüfung hängt: nach ${took} ms aufgegeben (Frist 1,5 s), kein Abruf`, [r, took]);
  ok(!h.logs.some((l) => l.includes("PDF-Hintergrund geht nicht")) && h.logs.filter((l) => l.includes("PDF-Hintergrund bis zur Frist der Frage nicht geprüft")).length === 1, "nicht als „geht nicht“ gemerkt, einmal im Protokoll", h.logs);
  // warm() prüft in Ruhe, da kommt ein Lernwort: osascript gleich beendet, die Prüfung bleibt offen
  let stopP = false;
  const acP = new AbortController();
  setTimeout(() => { stopP = true; acP.abort(); }, 300);
  t1 = Date.now();
  await h.w.warm(() => stopP, acP.signal);
  took = Date.now() - t1;
  ok(took < 2000 && !h.logs.some((l) => l.includes("PDF-Hintergrund geht nicht") || l.includes("PDF-Hintergrund geprüft")), `Prüfung in warm() abgebrochen: nach ${took} ms zurück, nicht als „geht nicht“ gemerkt`, [took, h.logs]);
  fs.writeFileSync(path.join(h.FAKE, "bg.json"), "{}");
  await h.w.warm(() => false);
  ok(h.logs.some((l) => l.includes("PDF-Hintergrund geprüft")), "warm(): in Ruhe noch einmal geprüft, bestanden", h.logs);
  const nBg = calls(h.FAKE).filter((c) => c.bg).length;
  ({ r } = await ask(h, doc, 1, { files: { pdf: "dokument.pdf" }, docExtra: pdfDoc }));
  ok(r.more && same(r.more.pages, [1]) && calls(h.FAKE).filter((c) => c.bg).length === nBg + 2, "danach angeboten, ohne neue Prüfung (nur hoehen und bilder des Dokuments)", [r, calls(h.FAKE).filter((c) => c.bg).length - nBg]);
  // Die Seitenhöhen eines neuen PDF-Stands hängen: ebenso nur bis zur Frist, beim nächsten Mal neu
  fs.writeFileSync(path.join(h.FAKE, "bg.json"), JSON.stringify({ delayMs: 5000 }));
  h.state.docs[doc].pdfVersion = 8;
  h.srv.meta(doc, { pdfVersion: 8 });
  t1 = Date.now();
  ({ r } = await ask(h, doc, 1, { files: { pdf: "dokument.pdf" }, docExtra: { ...pdfDoc, pdfVersion: 8 }, deadline: h.clock.t + 1500 }));
  took = Date.now() - t1;
  ok(same(r, { moreOff: "PDF-Hintergrund geht nicht" }) && took < 4000 && h.logs.some((l) => l.includes("nicht gelesen: Zeit um")), `Seitenhöhen hängen: nach ${took} ms aufgegeben, „Zeit um“ im Protokoll`, [r, took]);
  fs.writeFileSync(path.join(h.FAKE, "bg.json"), "{}");
  ({ r } = await ask(h, doc, 1, { files: { pdf: "dokument.pdf" }, docExtra: { ...pdfDoc, pdfVersion: 8 } }));
  ok(r.more && same(r.more.pages, [1]) && fs.existsSync(path.join(h.HOME, "seitenbilder", doc, "v8", "hoehen.json")), "nächste Frage: Höhen gelesen, Seite angeboten", r);
}

async function warmPdfTests() {
  console.log("== PDF: warm() bricht osascript ab; ein Hintergrund, der nie geht, hält warm() nicht auf");
  if (!tools) { console.log("  skip  PDF (pdfinfo/pdftoppm fehlen)"); return; }
  const h = harness();
  const doc = "PDF00002-AAAA", pdfDoc = { kind: "pdf", hasPDF: true, pdfVersion: 7 };
  const dir = path.join(h.HOME, "chats", doc);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "dokument.pdf"), makePDF([{ size: [595, 842] }, { size: [595, 842] }, { size: [595, 842] }]));
  h.state.docs[doc] = { pdfVersion: 7 };
  h.srv.meta(doc, { kind: "pdf", pageCount: 3, pdfVersion: 7 });
  // Die Prüfung von hintergrund.js bestanden (noch ohne Notizen im PDF)
  let { r } = await ask(h, doc, 1, { files: { pdf: "dokument.pdf" }, docExtra: pdfDoc });
  ok(same(r, {}) && h.logs.some((l) => l.includes("PDF-Hintergrund geprüft")), "geprüft", h.logs);
  const f = W.pdfFrames([768 * 842 / 595, 768 * 842 / 595, 768 * 842 / 595]);
  h.srv.add(doc, "m0", wire({ x: 100, y: f[0].y + 300 }));
  h.srv.add(doc, "m2", wire({ x: 100, y: f[2].y + 300 }));
  // Erst ein Notizbuch, dessen Seiten bis zur Frist nicht gezeichnet sind, dann das PDF: warm() nimmt das PDF zuerst
  const nbw = nb(40);
  for (const p of [0, 2, 4]) h.srv.add(nbw, `w${p}`, wire({ x: 60, y: top(p) + 100 }));
  ({ r } = await ask(h, nbw, 0, { deadline: h.clock.t - 1 }));
  ok(r.more && same(r.more.pages, []) && same(r.more.notReady, [3, 5]), "Notizbuch: Frist um, nichts gezeichnet", r.more);
  fs.writeFileSync(path.join(h.FAKE, "bg.json"), JSON.stringify({ failPages: [0, 2] }));
  ({ r } = await ask(h, doc, 1, { files: { pdf: "dokument.pdf" }, docExtra: pdfDoc }));
  ok(r.more && same(r.more.pages, []) && same(r.more.notReady, [1, 3]), "PDF: beide Hintergründe gescheitert, nicht bereit", r.more);
  // osascript braucht lange, ein Lernwort kommt nach 300 ms: gleich zurück, ohne Fehler im Protokoll
  fs.writeFileSync(path.join(h.FAKE, "bg.json"), JSON.stringify({ delayMs: 4000 }));
  let stop = false;
  const ac = new AbortController();
  setTimeout(() => { stop = true; ac.abort(); }, 300);
  let t1 = Date.now();
  await h.w.warm(() => stop, ac.signal);
  let took = Date.now() - t1;
  ok(took < 2000 && !h.logs.some((l) => l.includes("Hintergründe nicht gezeichnet")), `osascript in warm() abgebrochen: nach ${took} ms zurück (es bräuchte 4 s), kein Fehler im Protokoll`, [took, h.logs]);
  // Seite 3 des PDFs scheitert immer: warm() zeichnet Seite 1, lässt das PDF dann (die nächste Frage zu ihm versucht es
  // wieder) und zeichnet das Notizbuch vor. Vorher wie nach der Frage: im PDF nichts gezeichnet, es zuletzt gefragt
  fs.rmSync(path.join(h.HOME, "seitenbilder", doc), { recursive: true, force: true });
  fs.writeFileSync(path.join(h.FAKE, "bg.json"), JSON.stringify({ failPages: [0, 2] }));
  ({ r } = await ask(h, doc, 1, { files: { pdf: "dokument.pdf" }, docExtra: pdfDoc }));
  ok(r.more && same(r.more.notReady, [1, 3]) && cacheFiles(h, nbw).length === 0, "wieder nichts gezeichnet", [r.more, cacheFiles(h, nbw)]);
  fs.writeFileSync(path.join(h.FAKE, "bg.json"), JSON.stringify({ failPages: [2] }));
  await h.w.warm(() => false, new AbortController().signal);
  ok(cacheFiles(h, doc).length === 1 && cacheFiles(h, nbw).length === 2, "PDF-Seite 1 und die zwei Notizbuchseiten vorgezeichnet", [cacheFiles(h, doc), cacheFiles(h, nbw)]);
  const bilder = () => calls(h.FAKE).filter((c) => c.bg?.mode === "bilder").length;
  const nb0 = bilder();
  await h.w.warm(() => false, new AbortController().signal);
  ok(bilder() === nb0, "nächste Ruhepause: kein osascript mehr für die Seite, die nie geht", bilder() - nb0);
  // Nur die Frist der Frage um (osascript beendet): kein Fehler des Skripts im Protokoll, ein echter danach schon
  fs.writeFileSync(path.join(h.FAKE, "bg.json"), JSON.stringify({ delayMs: 3000 }));
  ({ r } = await ask(h, doc, 1, { files: { pdf: "dokument.pdf" }, docExtra: pdfDoc, deadline: h.clock.t + 1500 }));
  ok(r.more && same(r.more.pages, [1]) && same(r.more.notReady, [3]) && !h.logs.some((l) => l.includes("Hintergründe nicht gezeichnet")), "Frist der Frage um: Seite 3 nicht bereit, nichts im Protokoll", [r.more, h.logs]);
  fs.writeFileSync(path.join(h.FAKE, "bg.json"), JSON.stringify({ fail: true }));
  ({ r } = await ask(h, doc, 1, { files: { pdf: "dokument.pdf" }, docExtra: pdfDoc }));
  ok(h.logs.some((l) => l.includes("Hintergründe nicht gezeichnet") && l.includes("PDFKit kaputt")), "ein echter Fehler von osascript danach: im Protokoll", h.logs);
}

async function warmSlowPdfTests() {
  console.log("== PDF: ein langsames PDF zeichnet warm() über mehrere Ruhepausen fertig");
  if (!tools) { console.log("  skip  PDF (pdfinfo/pdftoppm fehlen)"); return; }
  const h = harness({ warmBatchMs: 1500 });
  const doc = "PDF00003-AAAA", pdfDoc = { kind: "pdf", hasPDF: true, pdfVersion: 3 };
  const dir = path.join(h.HOME, "chats", doc);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "dokument.pdf"), makePDF(Array.from({ length: 6 }, () => ({ size: [595, 842] }))));
  h.state.docs[doc] = { pdfVersion: 3 };
  h.srv.meta(doc, { kind: "pdf", pageCount: 6, pdfVersion: 3 });
  let { r } = await ask(h, doc, 5, { files: { pdf: "dokument.pdf" }, docExtra: pdfDoc });
  ok(same(r, {}) && h.logs.some((l) => l.includes("PDF-Hintergrund geprüft")), "geprüft", h.logs);
  const f = W.pdfFrames(Array.from({ length: 6 }, () => 768 * 842 / 595));
  for (const p of [0, 1, 2, 3]) h.srv.add(doc, `s${p}`, wire({ x: 100, y: f[p].y + 300 }));
  ({ r } = await ask(h, doc, 5, { files: { pdf: "dokument.pdf" }, docExtra: pdfDoc, deadline: h.clock.t - 1 }));
  ok(r.more && same(r.more.pages, []) && same(r.more.notReady, [4, 3, 2, 1].sort((a, b) => a - b)), "Frist um: vier Seiten nicht bereit", r.more);
  // Jede Seite braucht 0,5 s, ein Stapel in warm() darf hier 1,5 s: jede Ruhepause schafft ein paar Seiten und macht
  // beim nächsten Mal weiter, statt das PDF nach dem ersten zu langen Stapel liegen zu lassen
  fs.writeFileSync(path.join(h.FAKE, "bg.json"), JSON.stringify({ pageMs: 500 }));
  const counts = [];
  for (let pass = 0; pass < 6 && cacheFiles(h, doc).length < 4; pass++) {
    await h.w.warm(() => false, new AbortController().signal);
    counts.push(cacheFiles(h, doc).length);
  }
  ok(counts.length >= 2 && counts.at(-1) === 4 && counts.every((c, k) => c > (k ? counts[k - 1] : 0)), `über ${counts.length} Ruhepausen fertig gezeichnet, jede mit Fortschritt (${counts.join(", ")})`, counts);
  ok(h.logs.some((l) => l.includes("Zeit um nach 2 s")), "der zu lange Stapel steht einmal im Protokoll", h.logs);
  const bilder = () => calls(h.FAKE).filter((c) => c.bg?.mode === "bilder").length;
  const b0 = bilder();
  await h.w.warm(() => false, new AbortController().signal);
  ok(bilder() === b0, "danach kein osascript mehr in der Ruhepause", bilder() - b0);
  ({ r } = await ask(h, doc, 5, { files: { pdf: "dokument.pdf" }, docExtra: pdfDoc }));
  ok(r.more && same(r.more.pages, [1, 2, 3, 4]) && r.more.drawn === 0, "die nächste Frage bekommt alle vier, nichts neu gezeichnet", r.more);
}

async function warmStuckPdfTests() {
  console.log("== PDF: Hintergründe, die nie fertig werden: warm() lässt das PDF liegen, eine hängende Seite bleibt aus");
  if (!tools) { console.log("  skip  PDF (pdfinfo/pdftoppm fehlen)"); return; }
  const bilder = (h) => calls(h.FAKE).filter((c) => c.bg?.mode === "bilder" && c.bg.pdf === "dokument.pdf");
  const setBg = (h, cfg) => fs.writeFileSync(path.join(h.FAKE, "bg.json"), JSON.stringify(cfg));
  /// PDF mit n Seiten (A4), Notizen auf `written` (ab 0), dazu `extra` Striche auf der ersten davon; die Frage auf der
  /// letzten Seite kam mit abgelaufener Frist (nichts gezeichnet, warm() hat es vor sich; mit mehr als 500 Strichen ist
  /// auch die Kopie noch unfertig)
  async function slowPdf(h, doc, n, written, extra = 0) {
    const dir = path.join(h.HOME, "chats", doc);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, "dokument.pdf"), makePDF(Array.from({ length: n }, () => ({ size: [595, 842] }))));
    h.state.docs[doc] = { pdfVersion: 3 };
    h.srv.meta(doc, { kind: "pdf", pageCount: n, pdfVersion: 3 });
    const opts = { files: { pdf: "dokument.pdf" }, docExtra: { kind: "pdf", hasPDF: true, pdfVersion: 3 } };
    await ask(h, doc, n - 1, opts); // die Prüfung von hintergrund.js (noch ohne Notizen)
    const f = W.pdfFrames(Array.from({ length: n }, () => 768 * 842 / 595));
    for (const p of written) h.srv.add(doc, `s${p}`, wire({ x: 100, y: f[p].y + 300 }));
    for (let k = 0; k < extra; k++) h.srv.add(doc, `x${k}`, wire({ x: 100 + (k % 40) * 15, y: f[written[0]].y + 400 + Math.floor(k / 40) * 10, len: 10 }));
    const { r } = await ask(h, doc, n - 1, { ...opts, deadline: h.clock.t - 1 });
    return { opts, f, r };
  }
  /// Uhr des Moduls: steht, bis scale gesetzt wird (dann so viel schneller als die echte)
  const fastClock = () => ({
    base: Date.now(), at: Date.now(), scale: 0,
    get t() { return this.base + (Date.now() - this.at) * this.scale; },
    set t(v) { this.base = v; this.at = Date.now(); },
  });

  // Ein ganzer Stapel ohne einen Hintergrund (osascript braucht schon vor der ersten Seite zu lange): Die nächste
  // Ruhepause versucht es nicht wieder, erst die nächste Frage. Die Seite vorn bleibt eine Stunde aus (vielleicht war nur
  // osascript langsam)
  let h = harness({ warmBatchMs: 1500 });
  let doc = "PDF00005-AAAA";
  let { r, opts: o5 } = await slowPdf(h, doc, 4, [0, 1, 2]);
  ok(r.more && same(r.more.notReady, [1, 2, 3]), "Frist um: nichts gezeichnet", r.more);
  setBg(h, { delayMs: 3000 });
  await h.w.warm(() => false, new AbortController().signal);
  let b0 = bilder(h).length;
  ok(b0 === 1 && cacheFiles(h, doc).length === 0, "eine Ruhepause: ein Stapel, nach 1,5 s abgebrochen, nichts gezeichnet", b0);
  await h.w.warm(() => false, new AbortController().signal);
  ok(bilder(h).length === b0, "die nächste Ruhepause: kein osascript mehr", bilder(h).length - b0);
  ok(h.logs.some((l) => l.includes("Hintergrund von Seite 3 (PDF00005) nach 2 s nicht fertig, eine Stunde lang ausgelassen")), "im Protokoll: Seite 3 eine Stunde ausgelassen", h.logs.filter((l) => l.includes("ausgelassen")));
  // osascript wieder schnell: In der Stunde bekommt eine Frage die Seiten dahinter, danach auch diese
  setBg(h, {});
  h.clock.t += HOUR - MIN;
  ({ r } = await ask(h, doc, 3, o5));
  ok(r.more && same(r.more.pages, [1, 2]) && same(r.more.notReady, [3]), "kurz vor Ende der Stunde: die Seiten 1 und 2, Seite 3 noch nicht", r.more);
  h.clock.t += 2 * MIN;
  ({ r } = await ask(h, doc, 3, o5));
  ok(r.more && same(r.more.pages, [1, 2, 3]) && r.more.notReady.length === 0, "nach der Stunde: auch Seite 3", r.more);

  // Jede Seite braucht länger, als ein Stapel darf, und 24 Seiten sind drei Stapel: Die Minute von warm() endet mitten
  // im dritten. Die Uhr des Moduls läuft dafür 20-mal so schnell wie die echte (die Minute sind 3 s, ein Stapel darf 1 s
  // und steht für 20 s). Nach dieser Ruhepause lässt warm() das PDF liegen, statt in jeder eine Minute osascript laufen
  // zu lassen, und kommt zur Kopie des nächsten Dokuments
  const clock = fastClock();
  h = harness({ warmBatchMs: 1000, clock });
  doc = "PDF00006-AAAA";
  const rec = nb(65);
  for (let k = 0; k < 30; k++) h.srv.add(rec, `r${k}`, wire({ x: 40 + k * 20, y: top(k % 3) + 80 }));
  ({ r } = await slowPdf(h, doc, 26, Array.from({ length: 24 }, (_, i) => i)));
  ok(r.more && r.more.notReady.length === 24, "24 Seiten nicht bereit", r.more?.notReady.length);
  setBg(h, { pageMs: 1500 });
  clock.t = clock.t;
  clock.scale = 20;
  await h.w.warm(() => false, new AbortController().signal, [rec]);
  b0 = bilder(h).length;
  ok(b0 === 3 && cacheFiles(h, doc).length === 0 && !fs.existsSync(path.join(h.HOME, "spiegel", rec)), "eine Ruhepause: drei Stapel bis zur Frist, kein Hintergrund", b0);
  await h.w.warm(() => false, new AbortController().signal, [rec]);
  ok(bilder(h).length === b0 && fs.existsSync(path.join(h.HOME, "spiegel", rec, "stand.json")) && stand(h, rec).complete === true, "die nächste: kein osascript mehr, dafür die Kopie des nächsten Dokuments", [bilder(h).length - b0, h.srv.calls.map((c) => c.p.slice(0, 30))]);
  // Die erste Seite der ersten beiden Stapel (der dritte hätte am Mac keine ganzen 20 s mehr; hier läuft nur die Uhr des
  // Moduls schneller, osascript nicht, daher bekommt er hier seine ganze Zeit)
  ok(["24", "16"].every((n) => h.logs.some((l) => l.includes(`Hintergrund von Seite ${n} (PDF00006) nach 1 s nicht fertig, eine Stunde lang ausgelassen`))), "die erste Seite der Stapel: im Protokoll, eine Stunde ausgelassen", h.logs.filter((l) => l.includes("ausgelassen")));

  // Eine Seite hängt (die 6.): Die Fragen warten nicht bis zu ihrer Frist darauf, und die Seiten dahinter im selben Stapel
  // gibt es trotzdem
  h = harness({ warmBatchMs: 1500 });
  doc = "PDF00007-AAAA";
  let f, opts;
  ({ r, f, opts } = await slowPdf(h, doc, 10, [0, 1, 2, 3, 4, 5, 6, 7, 8]));
  setBg(h, { slowPages: { 5: 60000 } });
  await h.w.warm(() => false, new AbortController().signal);
  ok(same(bilder(h).at(-2)?.bg.specs.map((s) => Number(s.split(":")[0])), [8, 7, 6, 5, 4, 3, 2, 1]) && cacheFiles(h, doc).length === 4, "erste Ruhepause: 9, 8, 7 und 1 gezeichnet, an der 6 abgebrochen", cacheFiles(h, doc).length);
  // Dazu neue Notizen auf Seite 9 (ihr Hintergrund ist da): Dass die zweite Ruhepause sie neu zeichnet, ist kein
  // Fortschritt der Hintergründe
  h.srv.add(doc, "s8a", wire({ x: 300, y: f[8].y + 400 }));
  await ask(h, doc, 9, { ...opts, deadline: h.clock.t - 1 });
  await h.w.warm(() => false, new AbortController().signal);
  ok(h.logs.some((l) => l.includes("Hintergrund von Seite 6 (PDF00007) nach 2 s nicht fertig, eine Stunde lang ausgelassen")) && h.logs.some((l) => l.includes("1 Seite von PDF00007 vorgezeichnet")), "zweite: hängt allein an der 6, eine Stunde ausgelassen; Seite 9 neu gezeichnet", h.logs.filter((l) => l.includes("PDF00007")));
  b0 = bilder(h).length;
  await h.w.warm(() => false, new AbortController().signal);
  ok(bilder(h).length === b0, "dritte: kein osascript (ein Stapel ohne neuen Hintergrund, nur Seite 9 neu gezeichnet)", bilder(h).length - b0);
  let t1 = Date.now();
  ({ r } = await ask(h, doc, 9, { ...opts, deadline: h.clock.t + 3000 }));
  let took = Date.now() - t1;
  ok(took < 1500 && r.more && same(r.more.pages, [1, 2, 3, 4, 5, 7, 8, 9]) && same(r.more.notReady, [6]) && same(bilder(h).slice(b0).map((c) => c.bg.specs.length), [4]), `die Frage wartet nicht darauf (${took} ms, Frist 3 s): alles außer Seite 6`, [took, r.more]);
  await h.w.warm(() => false, new AbortController().signal);
  ok(bilder(h).length === b0 + 1, "danach kein osascript in der Ruhepause", bilder(h).length - b0);
  // Neue Notizen auf Seite 9 (ihr Hintergrund ist da): Die Ruhepause danach zeichnet sie, osascript braucht sie nicht
  h.srv.add(doc, "s8b", wire({ x: 200, y: f[8].y + 500 }));
  ({ r } = await ask(h, doc, 9, { ...opts, deadline: h.clock.t - 1 }));
  b0 = bilder(h).length;
  const l0 = h.logs.length;
  await h.w.warm(() => false, new AbortController().signal);
  await h.w.warm(() => false, new AbortController().signal);
  ok(bilder(h).length === b0 && h.logs.slice(l0).some((l) => l.includes("1 Seite von PDF00007 vorgezeichnet")), "neue Notizen auf Seite 9: vorgezeichnet, ohne osascript", bilder(h).length - b0);
  // Nach der Stunde versucht der Helfer die Seite wieder (hier eine Frage, deren Frist für einen ganzen Stapel reicht);
  // hängt sie wieder, bleibt sie einen Tag aus, danach versucht er sie wieder
  const tried = (from) => bilder(h).slice(from).map((c) => c.bg.specs.map((s) => s.split(":")[0]));
  const dayLong = () => h.logs.filter((l) => l.includes("Hintergrund von Seite 6 (PDF00007) nach 2 s nicht fertig, einen Tag lang ausgelassen")).length;
  h.clock.t += HOUR + MIN;
  b0 = bilder(h).length;
  ({ r } = await ask(h, doc, 9, { ...opts, deadline: h.clock.t + 1500 }));
  ok(r.more && same(r.more.notReady, [6]) && same(tried(b0), [["5"]]) && dayLong() === 1, "eine Stunde später: wieder versucht, hängt wieder, jetzt einen Tag aus", [r.more, tried(b0), dayLong()]);
  h.clock.t += 12 * HOUR;
  b0 = bilder(h).length;
  ({ r } = await ask(h, doc, 9, { ...opts, deadline: h.clock.t + 1500 }));
  ok(r.more && same(r.more.notReady, [6]) && bilder(h).length === b0, "zwölf Stunden danach: noch aus, kein osascript", tried(b0));
  h.clock.t += 12 * HOUR + MIN;
  b0 = bilder(h).length;
  ({ r } = await ask(h, doc, 9, { ...opts, deadline: h.clock.t + 1500 }));
  ok(r.more && same(r.more.notReady, [6]) && same(tried(b0), [["5"]]) && dayLong() === 2, "einen Tag später: wieder versucht (hängt noch, wieder einen Tag)", [tried(b0), dayLong()]);
  // Wer sie nur alle paar Tage braucht: drei Tage nach dem Ende der Pause hängt sie wieder, das bleibt ein Tag. Erst mehr
  // als eine Woche danach zählt das frühere Hängen nicht mehr (dann wieder nur eine Stunde)
  const hourLong = () => h.logs.filter((l) => l.includes("Hintergrund von Seite 6 (PDF00007) nach 2 s nicht fertig, eine Stunde lang ausgelassen")).length;
  h.clock.t += DAY + 3 * DAY;
  b0 = bilder(h).length;
  ({ r } = await ask(h, doc, 9, { ...opts, deadline: h.clock.t + 1500 }));
  ok(same(tried(b0), [["5"]]) && dayLong() === 3 && hourLong() === 1, "drei Tage nach der Pause: hängt wieder, einen Tag aus", [tried(b0), dayLong(), hourLong()]);
  h.clock.t += DAY + WEEK + MIN;
  b0 = bilder(h).length;
  ({ r } = await ask(h, doc, 9, { ...opts, deadline: h.clock.t + 1500 }));
  ok(same(tried(b0), [["5"]]) && dayLong() === 3 && hourLong() === 2, "mehr als eine Woche nach der Pause: hängt wieder, nur eine Stunde aus", [tried(b0), dayLong(), hourLong()]);

  // Die Seite vorn im ersten Stapel hängt, alle anderen gehen schnell, und die Minute endet: Es kamen neue Hintergründe
  // dazu, also behält warm() das PDF und zeichnet in der nächsten Ruhepause weiter (Uhr wieder 20-mal so schnell)
  const c8 = fastClock();
  h = harness({ warmBatchMs: 1000, clock: c8 });
  doc = "PDF00008-AAAA";
  await slowPdf(h, doc, 26, Array.from({ length: 24 }, (_, i) => i));
  setBg(h, { pageMs: 150, slowPages: { 23: 60000 } });
  c8.t = c8.t;
  c8.scale = 20;
  await h.w.warm(() => false, new AbortController().signal);
  const n1 = cacheFiles(h, doc).length;
  await h.w.warm(() => false, new AbortController().signal);
  const n2 = cacheFiles(h, doc).length;
  ok(n1 > 0 && n2 > n1 && h.logs.some((l) => l.includes("Hintergrund von Seite 24 (PDF00008) nach 1 s nicht fertig, eine Stunde lang ausgelassen")), `die Seite vorn hängt, die übrigen nicht: die nächste Ruhepause zeichnet weiter (${n1}, dann ${n2} Seiten)`, [n1, n2, h.logs.filter((l) => l.includes("PDF00008"))]);

  // Die Minute endet mitten in einem Stapel, der deshalb nur kürzer laufen durfte und nichts fertig bekam: Das liegt an
  // der Frist, nicht an der Seite. warm() behält das PDF und zeichnet in der nächsten Ruhepause weiter. Die Uhr des
  // Moduls läuft hier wie die echte; beim Holen der Kopie (mehr als 500 Striche) springt sie bis 2 s vor die Frist
  const c9 = fastClock(), srv9 = fakeServer(), inner9 = srv9.api;
  let jump = 0;
  srv9.api = async (...a) => { const res = await inner9(...a); if (jump) { c9.t += jump; jump = 0; } return res; };
  h = harness({ warmBatchMs: 3000, clock: c9, srv: srv9 });
  doc = "PDF00009-AAAA";
  ({ r } = await slowPdf(h, doc, 4, [0, 1, 2], 600));
  ok(r.moreOff === "Spiegel nicht fertig", "Frist um: Kopie noch unfertig", r);
  setBg(h, { slowPages: { 2: 60000 } });
  c9.t = c9.t;
  c9.scale = 1;
  jump = 60000 - 2000 - 150;
  b0 = bilder(h).length;
  await h.w.warm(() => false, new AbortController().signal);
  ok(stand(h, doc).complete === true && bilder(h).length === b0 + 1 && cacheFiles(h, doc).length === 0 && !h.logs.some((l) => l.includes("PDF00009") && l.includes("ausgelassen")), "Minute um im verkürzten Stapel, nichts fertig: nichts ausgelassen", [bilder(h).length - b0, cacheFiles(h, doc).length, h.logs.filter((l) => l.includes("PDF00009"))]);
  setBg(h, {});
  await h.w.warm(() => false, new AbortController().signal);
  ok(bilder(h).length === b0 + 2 && cacheFiles(h, doc).length === 3, "die nächste Ruhepause zeichnet die drei Seiten", [bilder(h).length - b0, cacheFiles(h, doc).length]);
}

async function prewarmTests() {
  console.log("== warm(): fehlende Kopien der Dokumente mit den letzten Fragen gleich holen");
  const h = harness();
  const doc = nb(60), old = nb(61), del = nb(62);
  for (let k = 0; k < 1300; k++) h.srv.add(doc, `p${k}`, wire({ x: 40 + (k % 12) * 55, y: top(k % 20) + 80 + (k % 7) * 30 }));
  h.srv.meta(doc, { pageCount: 20 });
  await h.w.warm(() => true, new AbortController().signal, [doc]);
  ok(h.srv.calls.length === 0, "mit shouldStop: nichts geholt", h.srv.calls.length);
  await h.w.warm(() => false, new AbortController().signal, [doc, "../x", 7]);
  ok(stand(h, doc).complete === true && h.srv.calls.length === 3 && h.srv.calls.every((c) => c.p.startsWith(`/api/doc/${doc}/strokes?`)) && !fs.existsSync(path.join(h.HOME, "seitenbilder", doc)), "Kopie fertig geholt (3 Abrufe), nichts gezeichnet, ungültige Kennungen übergangen", h.srv.calls.map((c) => c.p));
  await h.w.warm(() => false, new AbortController().signal, [doc]);
  ok(h.srv.calls.length === 3, "fertige Kopie: kein Abruf mehr in der Ruhepause", h.srv.calls.length);
  // Die erste Frage danach holt nur noch, was seither dazukam
  h.srv.add(doc, "neu", wire({ x: 300, y: top(5) + 400 }));
  const { r } = await ask(h, doc, 10);
  ok(r.more && r.more.pages.length && h.srv.calls.length === 4, "die erste Frage danach: ein Abruf, Seiten angeboten", [h.srv.calls.length, r.more?.pages]);
  // Höchstens die zwei neuesten; ein am Server gelöschtes Dokument nur einmal
  h.srv.add(old, "a", wire({ x: 50, y: top(0) + 100 }));
  h.srv.add(del, "b", wire({ x: 50, y: top(0) + 100 }));
  h.srv.meta(del, { deleted: true });
  const c0 = h.srv.calls.length;
  await h.w.warm(() => false, new AbortController().signal, [del, doc, old]);
  ok(h.srv.calls.length === c0 + 1 && h.srv.calls.at(-1).p.startsWith(`/api/doc/${del}/`) && !fs.existsSync(path.join(h.HOME, "spiegel", old)), "nur die zwei neuesten: das gelöschte einmal gefragt, das dritte nicht", h.srv.calls.slice(c0).map((c) => c.p));
  await h.w.warm(() => false, new AbortController().signal, [del, doc]);
  ok(h.srv.calls.length === c0 + 1, "das gelöschte danach nicht mehr", h.srv.calls.slice(c0).map((c) => c.p));
  // Unfertig (Abruf abgebrochen): die nächste Ruhepause macht weiter
  const big = nb(63);
  for (let k = 0; k < 1200; k++) h.srv.add(big, `q${k}`, wire({ x: 40 + (k % 12) * 55, y: top(k % 10) + 80 }));
  h.srv.delayMs = 3000;
  const ac = new AbortController();
  setTimeout(() => ac.abort(), 200);
  await h.w.warm(() => ac.signal.aborted, ac.signal, [big]);
  h.srv.delayMs = 0;
  const c1 = h.srv.calls.length;
  await h.w.warm(() => false, new AbortController().signal, [big]);
  ok(stand(h, big).complete === true && h.srv.calls.length - c1 === 3, "abgebrochen, dann in der nächsten Ruhepause fertig geholt", h.srv.calls.length - c1);

  // Abgeschaltet (morePages 0 und 0): keine Kopie vorab
  const off = harness({ cfg: { morePages: { quick: 0, thorough: 0 } } });
  for (let k = 0; k < 600; k++) off.srv.add(doc, `p${k}`, wire({ x: 40 + (k % 12) * 55, y: top(k % 20) + 80 }));
  await off.w.warm(() => false, new AbortController().signal, [doc]);
  ok(off.srv.calls.length === 0 && !fs.existsSync(path.join(off.HOME, "spiegel")), "abgeschaltet: nichts geholt", off.srv.calls.map((c) => c.p));

  // Ein Lernwort kommt in der Pause zwischen zwei Abrufen: warm() wartet ihr Ende nicht ab
  const srv = fakeServer(), inner = srv.api;
  let afterCall = null;
  srv.api = async (...a) => { const res = await inner(...a); afterCall?.(); return res; };
  const hp = harness({ srv });
  const pd = nb(66);
  for (let k = 0; k < 1300; k++) srv.add(pd, `q${k}`, wire({ x: 40 + (k % 12) * 55, y: top(k % 10) + 80 }));
  const ap = new AbortController();
  let abortedAt = 0;
  afterCall = () => { afterCall = null; setTimeout(() => { abortedAt = Date.now(); ap.abort(); }, 20); };
  await hp.w.warm(() => ap.signal.aborted, ap.signal, [pd]);
  const late = Date.now() - abortedAt;
  ok(late < 60 && srv.calls.length === 1, `in der Pause zwischen zwei Abrufen abgebrochen: ${late} ms danach zurück (die Pause dauert 150 ms)`, [late, srv.calls.length]);

  // Die Platte ist voll: Die Ruhepause scheitert erst nach dem Abruf (beim Anhängen an die Kopie). Danach liest eine
  // Stunde lang keine mehr dieselben Zeilen am Server, nur um sie wegzuwerfen
  const hf = harness();
  const fd = nb(68);
  for (let k = 0; k < 600; k++) hf.srv.add(fd, `f${k}`, wire({ x: 40 + (k % 12) * 55, y: top(k % 10) + 80 }));
  const append = fs.appendFileSync, errs = [];
  fs.appendFileSync = (file, ...rest) => {
    if (String(file).startsWith(path.join(hf.HOME, "spiegel"))) throw Object.assign(new Error("ENOSPC: no space left on device, write"), { code: "ENOSPC" });
    return append(file, ...rest);
  };
  try {
    for (let k = 0; k < 3; k++) await hf.w.warm(() => false, new AbortController().signal, [fd]).catch((e) => errs.push(e.code));
    ok(same(errs, ["ENOSPC"]) && hf.srv.calls.length === 1, "Platte voll: der Fehler geht weiter, danach kein Abruf mehr", [errs, hf.srv.calls.length]);
    hf.clock.t += 61 * MIN;
    await hf.w.warm(() => false, new AbortController().signal, [fd]).catch((e) => errs.push(e.code));
    ok(same(errs, ["ENOSPC", "ENOSPC"]) && hf.srv.calls.length === 2, "eine Stunde später der nächste Versuch", [errs, hf.srv.calls.length]);
  } finally {
    fs.appendFileSync = append;
  }
  // Wieder Platz: Solange keine Frage ihre Kopie schreiben konnte, wartet warm() die Stunde ab. Konnte eine ihre Kopie
  // schreiben (auch nur bis zu ihrer Frist zum Teil), darf warm() gleich wieder
  const fd2 = nb(69), fd3 = nb(64), fd4 = nb(59);
  for (let k = 0; k < 10; k++) hf.srv.add(fd2, `g${k}`, wire({ x: 40 + k * 20, y: top(0) + 80 }));
  for (let k = 0; k < 1200; k++) hf.srv.add(fd3, `e${k}`, wire({ x: 40 + (k % 12) * 55, y: top(k % 10) + 80 }));
  let f0 = hf.srv.calls.length;
  await hf.w.warm(() => false, new AbortController().signal, [fd2]);
  ok(hf.srv.calls.length === f0, "wieder Platz, noch keine Frage: warm() wartet die Stunde ab", hf.srv.calls.length - f0);
  const { r: rg } = await ask(hf, fd, -1);
  await hf.w.warm(() => false, new AbortController().signal, [fd2]);
  ok(rg.moreOff === "Seite der Frage gelöscht" && hf.srv.calls.length === f0, "eine Frage, die nichts schreibt (ihre Seite gelöscht): warm() wartet weiter", [rg, hf.srv.calls.length - f0]);
  const { r: rf } = await ask(hf, fd3, 0, { deadline: hf.clock.t - 1 });
  f0 = hf.srv.calls.length;
  await hf.w.warm(() => false, new AbortController().signal, [fd2]);
  ok(rf.moreOff === "Spiegel nicht fertig" && hf.srv.calls.length > f0 && stand(hf, fd3).complete === true && stand(hf, fd2).complete === true, "eine Frage, deren Kopie sich bis zur Frist zum Teil schreiben ließ: warm() holt gleich den Rest", [rf, hf.srv.calls.length - f0]);
  // Trifft der Fehler nur warm() (hier nur die Kopie von fd4), gibt eine Frage es höchstens einmal je Stunde frei: sonst
  // läse warm() nach jeder Frage dieselben Zeilen am Server, nur um sie wegzuwerfen
  for (let k = 0; k < 10; k++) hf.srv.add(fd4, `h${k}`, wire({ x: 40 + k * 20, y: top(1) + 80 }));
  fs.appendFileSync = (file, ...rest) => {
    if (String(file).startsWith(path.join(hf.HOME, "spiegel", fd4))) throw Object.assign(new Error("ENOSPC: no space left on device, write"), { code: "ENOSPC" });
    return append(file, ...rest);
  };
  try {
    errs.length = 0;
    await hf.w.warm(() => false, new AbortController().signal, [fd4]).catch((e) => errs.push(e.code));
    await ask(hf, fd3, 0);
    f0 = hf.srv.calls.length;
    await hf.w.warm(() => false, new AbortController().signal, [fd4]).catch((e) => errs.push(e.code));
    ok(same(errs, ["ENOSPC"]) && hf.srv.calls.length === f0, "scheitert warm() gleich wieder: die nächste Frage gibt es in dieser Stunde nicht frei", [errs, hf.srv.calls.length - f0]);
    hf.clock.t += HOUR + MIN;
    await hf.w.warm(() => false, new AbortController().signal, [fd4]).catch((e) => errs.push(e.code));
    ok(same(errs, ["ENOSPC", "ENOSPC"]), "nach der Stunde versucht warm() es wieder", errs);
    // Eine Stunde nach dem letzten Freigeben gibt eine Frage, deren Kopie sich schreiben ließ, warm() wieder frei
    await ask(hf, fd3, 0);
    f0 = hf.srv.calls.length;
    await hf.w.warm(() => false, new AbortController().signal, [fd4]).catch((e) => errs.push(e.code));
    ok(same(errs, ["ENOSPC", "ENOSPC", "ENOSPC"]) && hf.srv.calls.length > f0, "eine Stunde nach dem letzten Freigeben: die nächste Frage gibt warm() wieder frei", [errs, hf.srv.calls.length - f0]);
  } finally {
    fs.appendFileSync = append;
  }

  // Ist die Minute mitten im Holen einer Kopie um, sagt warm() das (der Helfer macht dann gleich weiter, statt erst beim
  // nächsten Nachsehen in Minuten); jeder Abruf dauert hier 25 s auf der Uhr des Moduls
  const slowSrv = fakeServer(), slowInner = slowSrv.api, slowClock = { t: Date.now() };
  slowSrv.api = async (...a) => { slowClock.t += 25000; return slowInner(...a); };
  const hs = harness({ srv: slowSrv, clock: slowClock });
  const md = nb(67);
  for (let k = 0; k < 2000; k++) slowSrv.add(md, `m${k}`, wire({ x: 40 + (k % 12) * 55, y: top(k % 10) + 80 }));
  let more = await hs.w.warm(() => false, new AbortController().signal, [md]);
  ok(more === true && slowSrv.calls.length === 3 && stand(hs, md).complete === false, "Minute um mitten im Holen: true", [more, slowSrv.calls.length]);
  more = await hs.w.warm(() => false, new AbortController().signal, [md]);
  ok(more === false && stand(hs, md).complete === true, "fertig geholt: false", [more, slowSrv.calls.length]);
}

async function pruneTests() {
  console.log("== Aufräumen");
  const h = harness();
  const doc = nb(30), old = nb(31), big = nb(32);
  h.srv.add(doc, "a", wire({ x: 50, y: top(0) + 100 }));
  h.srv.add(doc, "b", wire({ x: 50, y: top(1) + 100 }));
  h.srv.add(doc, "c", wire({ x: 50, y: top(2) + 100 }));
  await ask(h, doc, 0);
  const dir = path.join(h.HOME, "seitenbilder", doc);
  const [f1, f2] = cacheFiles(h, doc);
  const t = h.clock.t;
  fs.utimesSync(path.join(dir, f1), new Date(t - 31 * DAY), new Date(t - 31 * DAY));
  fs.utimesSync(path.join(dir, f2), new Date(t - 29 * DAY), new Date(t - 29 * DAY));
  // Ein Dokument, das 91 Tage nicht gebraucht wurde
  h.srv.add(old, "o", wire({ x: 50, y: top(0) + 100 }));
  h.srv.add(old, "o2", wire({ x: 50, y: top(1) + 100 }));
  h.clock.t = t - 91 * DAY;
  await ask(h, old, 0);
  h.clock.t = t;
  // 4 × 100 MB (dünn besetzt) bei einem Dokument: über 300 MB, die älteste fällt weg
  const bdir = path.join(h.HOME, "seitenbilder", big);
  fs.mkdirSync(path.join(bdir, "v5"), { recursive: true });
  ["a", "b", "c"].forEach((n, i) => { const f = path.join(bdir, `${n.repeat(40)}.pdf`); fs.writeFileSync(f, ""); fs.truncateSync(f, 100e6); fs.utimesSync(f, new Date(t - (4 - i) * 3600000), new Date(t - (4 - i) * 3600000)); });
  const bgf = path.join(bdir, "v5", "bg-0.jpg");
  fs.writeFileSync(bgf, "");
  fs.truncateSync(bgf, 100e6);
  fs.utimesSync(bgf, new Date(t - 3600000), new Date(t - 3600000));
  await h.w.prune();
  ok(!fs.existsSync(path.join(dir, f1)) && fs.existsSync(path.join(dir, f2)) && cacheFiles(h, doc).length === 1, "Seiten, 30 Tage nicht gebraucht, weg; jüngere bleiben", cacheFiles(h, doc));
  ok(fs.existsSync(path.join(h.HOME, "spiegel", doc, "stand.json")), "Spiegel in Gebrauch bleibt");
  ok(!fs.existsSync(path.join(h.HOME, "spiegel", old)) && !fs.existsSync(path.join(h.HOME, "seitenbilder", old)), "Dokument 90 Tage nicht gebraucht: Spiegel und Seiten weg");
  ok(!fs.existsSync(path.join(bdir, `${"a".repeat(40)}.pdf`)) && fs.existsSync(path.join(bdir, `${"b".repeat(40)}.pdf`)) && fs.existsSync(bgf), "über 300 MB: die älteste Datei weg, bis es passt", ls(bdir));
  ok(h.logs.some((l) => l.includes("90 Tagen")), "im Protokoll");
  // Zwischendateien, die ein hart beendeter Helfer liegen ließ: nach einem Tag weg; frische und fremde bleiben
  const sdir = path.join(h.HOME, "spiegel", doc);
  const stale = [path.join(sdir, "striche.ndjson.4711.tmp"), path.join(sdir, "stand.json.4711.tmp"), path.join(h.HOME, "hintergrund.js.4711.tmp")];
  const others = [path.join(sdir, "notiz.4711.tmp"), path.join(h.HOME, "state.json.4711.tmp")];
  const young = path.join(sdir, "striche.ndjson.4712.tmp");
  for (const f of [...stale, ...others, young]) fs.writeFileSync(f, "x");
  for (const f of [...stale, ...others]) fs.utimesSync(f, new Date(t - 2 * DAY), new Date(t - 2 * DAY));
  await h.w.prune();
  ok(stale.every((f) => !fs.existsSync(f)) && others.every((f) => fs.existsSync(f)) && fs.existsSync(young) && fs.existsSync(path.join(sdir, "stand.json")),
    "Zwischendateien von striche.ndjson, stand.json, hintergrund.js nach einem Tag weg; jüngere und fremde bleiben", [ls(sdir), ls(h.HOME)]);
  // Schreiben scheitert (an der Stelle einer Seite liegt hier ein Ordner): Der Fehler geht weiter, keine halbe Kopie bleibt
  const d2 = nb(33);
  h.srv.add(d2, "a", wire({ x: 50, y: top(0) + 100 }));
  h.srv.add(d2, "b", wire({ x: 50, y: top(1) + 100 }));
  await ask(h, d2, 0);
  const pdir = path.join(h.HOME, "seitenbilder", d2), [page] = cacheFiles(h, d2);
  fs.rmSync(path.join(pdir, page));
  fs.mkdirSync(path.join(pdir, page, "x"), { recursive: true });
  let err = null;
  try { await ask(h, d2, 0); } catch (e) { err = e; }
  ok(err?.code === "EISDIR" && !ls(pdir).some((n) => n.endsWith(".tmp")), "Schreiben gescheitert: Fehler geht weiter, keine Zwischendatei", [err?.code, ls(pdir)]);
}

async function measure() {
  console.log("== Messung");
  const frame = { y: top(2), h: A4H };
  // Dichte Seite wie im Prototyp (26 Zeilen, Zittern je Punkt)
  const dense = [];
  let seed = 7;
  const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
  for (let line = 0; line < 26; line++) {
    const by = frame.y + 60 + line * 38;
    let x = 40;
    while (x < 720) {
      const letters = 3 + Math.floor(rnd() * 6);
      for (let s = 0; s < Math.ceil(letters / 2); s++) {
        const p = [], n = 25 + Math.floor(rnd() * 25);
        for (let k = 0; k < n; k++) {
          const t = k / n;
          p.push([+(x + t * 22 + 4 * Math.sin(t * 9 + s)).toFixed(2), +(by - 10 * Math.abs(Math.sin(t * 7 + s)) + rnd()).toFixed(2), +(t * 0.4).toFixed(3), 3.15, 3.15, 1, 0.5, 0.8, 1.2, 0.222]);
        }
        dense.push(JSON.stringify({ c: [0.1, 0.1, 0.11, 1], ink: "com.apple.ink.pen", p }));
        x += 24;
      }
      x += 14;
    }
  }
  // 300 Striche glatte Handschrift (ohne Zittern), Punkte etwa alle 1,2 Seitenpunkte
  const smooth = [];
  seed = 11;
  let line = 0, x = 40;
  for (let k = 0; k < 300; k++) {
    const by = frame.y + 70 + line * 36, len = 8 + rnd() * 18, n = Math.max(2, Math.round(len * 2.2 / 1.2)), ph = rnd() * 6, amp = 4 + rnd() * 6;
    const p = [];
    for (let j = 0; j < n; j++) {
      const t = j / (n - 1);
      p.push([+(x + t * len + 2.5 * Math.sin(t * 6.3 + ph)).toFixed(2), +(by - amp * Math.abs(Math.sin(t * 3.1 + ph))).toFixed(2), +(t * 0.3).toFixed(3), 2.6 + 0.4 * Math.sin(t * 3), 2.6, 1, 0.6, 0.8, 1.2, 0.27]);
    }
    smooth.push(JSON.stringify({ c: [0.05, 0.05, 0.3, 1], ink: "com.apple.ink.pen", p }));
    x += len + 4 + (rnd() < 0.25 ? 10 : 0);
    if (x > 720) { x = 40; line++; }
  }
  for (const [name, data] of [["dichte Seite (Prototyp)", dense], ["300 Striche", smooth]]) {
    const strokes = data.map(W.compactStroke);
    let best = Infinity, pdf;
    for (let i = 0; i < 5; i++) {
      const t0 = performance.now();
      pdf = W.pagePDF({ frame, strokes, label: "Seite 3" });
      best = Math.min(best, performance.now() - t0);
    }
    const points = strokes.reduce((a, s) => a + s.p.length / 3, 0);
    console.log(`  Messung ${name}: ${strokes.length} Striche, ${points} Punkte, ${best.toFixed(1)} ms, ${(pdf.length / 1000).toFixed(1)} KB`);
    ok(best < 2000 && pdf.length < 600000, `${name}: unter 2 s und 600 KB`);
  }
}

async function main() {
  pureTests();
  pageTests();
  await stateTests();
  await pdfTests();
  await warmPdfTests();
  await warmSlowPdfTests();
  await warmStuckPdfTests();
  await prewarmTests();
  await pruneTests();
  await measure();
  if (!failures && !process.env.KEEP) fs.rmSync(TMP, { recursive: true, force: true });
  console.log(`\n${passes} passed, ${failures} failed${failures || process.env.KEEP ? ` (Dateien: ${TMP})` : ""}`);
  process.exit(failures ? 1 : 0);
}
main().catch((e) => { console.error(e); process.exit(2); });
