// BetterNotes – LaTeX-Modus des Helfers (läuft im Helfer am Mac, geladen von helfer.mjs).
//
// Ein Projektordner am Mac (etwa ~/Documents/ClaudeCode/Exciting Games) mit einer Datei notizbuch.json gehört zu einem
// Ordner im Notizbuch. Jede Haupt-.tex darin (eine mit \documentclass) wird dort ein PDF-Dokument. Ändert sich eine
// Quelldatei, egal ob durch einen Auftrag vom iPad, einen Thread in der Claude-App oder Mathias selbst, setzt der Helfer
// das Dokument neu und tauscht das PDF im Notizbuch aus.
//
// Gesetzt wird auf EINE lange Seite (nb-lang.tex vor dem Dokument, die Präambel bleibt unverändert): Seitenumbrüche
// verschieben dann nichts. Was Mathias schon geschrieben hat, wandert mit: Jede Gruppe von Strichen hängt über SyncTeX an
// einer Zeile im Quelltext. Nach dem Neusetzen wird sie über den Unterschied alt → neu an die neue Lage dieser Zeile
// gerückt. Wurde genau ihre Zeile umgeschrieben, rückt sie an den Anfang der neuen Fassung (und zählt als „geändert“).
// Verschoben wird wie mit dem Lasso im Browser: alter Strich weg, derselbe mit dy (und neuer ID) dazu.
//
// Zustand je Dokument in <Projekt>/.notizbuch/<Name>/: zustand.json (Dokument-ID, zuletzt gesetzter Stand), bau/
// (Ausgabe von latexmk), stand/ (die Quellen und die SyncTeX-Datei des Stands, der gerade im Notizbuch liegt),
// fehler.txt (der letzte Fehler beim Setzen; fehlt, wenn alles ging).

import { execFile } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import zlib from "node:zlib";

// ---------- Die lange Seite ----------

/// Wird vor das Dokument gesetzt (latexmk -usepretex). Erste Runde: Seite 14450 pt hoch, am Ende die gebrauchte Höhe
/// in die .aux; ab der zweiten Runde ist die Seite genau so hoch. \newpage und \clearpage machen nur Abstand (bis zum
/// Ende, dann wieder wie gewohnt). Wird das Dokument länger als eine Seite fassen kann (≈ 5 m), bleiben es mehrere
/// Seiten dieser Höhe. \nb@seite hält Breite und Höhe fest, mit der gesetzt wurde (für die Lage der Striche).
export const PRETEX = String.raw`% BetterNotes: eine lange Seite (vom Helfer vor das Dokument gesetzt)
\makeatletter
\ifdefined\AddToHook\def\nb@hook{\AddToHook{begindocument/end}}\else\def\nb@hook{\AtBeginDocument}\fi
% Wo im A4-PDF eine neue Seite beginnt: kurze gestrichelte Linie links und rechts mit „S. n“ (marken.tex vom Helfer)
\def\nb@m#1#2{\put(0,-#1){\nb@grau{\multiput(14,0)(6,0){5}{\rule{3pt}{0.4pt}}\put(14,3.5){\fontsize{6}{7}\selectfont S.~#2}%
  \multiput(\strip@pt\dimexpr\paperwidth-46pt\relax,0)(6,0){5}{\rule{3pt}{0.4pt}}%
  \put(\strip@pt\dimexpr\paperwidth-46pt\relax,3.5){\fontsize{6}{7}\selectfont S.~#2}}}}
\def\nb@grau#1{\ifdefined\textcolor\textcolor[gray]{0.55}{#1}\else#1\fi}
\nb@hook{%
  \ifdefined\nbMarken\InputIfFileExists{\nbMarken}{}{}\fi
  \@ifundefined{nb@allemarken}{}{\ifdefined\AddToHook\AddToHook{shipout/background}{\ifnum\value{page}=1 \nb@allemarken\fi}\fi}%
  \@ifundefined{nb@hoehe}{\gdef\nb@hoehe{14450pt}}{}%
  \global\paperheight=\nb@hoehe\relax
  \@ifundefined{pdfpageheight}{}{\global\pdfpageheight=\paperheight}%
  \@ifundefined{pageheight}{}{\global\pageheight=\paperheight}%
  \global\textheight=14200pt\relax \global\vsize=\textheight
  \global\let\nb@newpage\newpage \global\let\nb@clearpage\clearpage \global\let\nb@cleardoublepage\cleardoublepage
  \gdef\newpage{\par\bigskip}\gdef\clearpage{\par\bigskip}\gdef\cleardoublepage{\par\bigskip}%
}
\AtEndDocument{\par\penalty\z@
  \immediate\write\@auxout{\gdef\string\nb@seite{\the\paperwidth/\the\paperheight}}%
  \ifnum\value{page}>1
    \immediate\write\@auxout{\gdef\string\nb@hoehe{14450pt}}%
  \else
    \immediate\write\@auxout{\gdef\string\nb@hoehe{\the\dimexpr\topmargin+1in+\headheight+\headsep+\pagetotal+\pagedepth+2cm\relax}}%
  \fi
  \global\let\newpage\nb@newpage \global\let\clearpage\nb@clearpage \global\let\cleardoublepage\nb@cleardoublepage}
\makeatother
`;

// Seitenmaße der App: Seite 768 breit, 6 Abstand oben und zwischen den Seiten (PageLayout.swift)
export const PAGE_WIDTH = 768;
export const PAGE_GAP = 6;
const PT_TO_BP = 72 / 72.27;

// ---------- SyncTeX lesen ----------

/// Liest eine SyncTeX-Datei (Text). Ergebnis: inputs (Nummer → Pfad), rows: die gesetzten Zeilen (hbox direkt in einer
/// vbox), je {page, v (Grundlinie, bp ab Seitenoberkante), top, bottom, tag, line}; tag/line ist die Quellzeile, aus der
/// das meiste in dieser Zeile stammt.
export function parseSynctex(text) {
  const inputs = new Map();
  let unit = 1, mag = 1000, xo = 0, yo = 0;
  const rows = [];
  const stack = []; // je offene Box: {kind, row|null}
  let page = 0;
  const lines = text.split("\n");
  let i = 0;
  for (; i < lines.length; i++) {
    const l = lines[i];
    if (l.startsWith("Input:")) {
      const m = /^Input:(\d+):(.*)$/.exec(l);
      if (m) inputs.set(Number(m[1]), m[2]);
    } else if (l.startsWith("Unit:")) unit = Number(l.slice(5)) || 1;
    else if (l.startsWith("Magnification:")) mag = Number(l.slice(14)) || 1000;
    else if (l.startsWith("X Offset:")) xo = Number(l.slice(9)) || 0;
    else if (l.startsWith("Y Offset:")) yo = Number(l.slice(9)) || 0;
    else if (l.startsWith("Content:")) { i++; break; }
  }
  const toBP = (sp) => ((sp * unit) / 65536) * PT_TO_BP * (mag / 1000) + yo * 0;
  void xo;
  for (; i < lines.length; i++) {
    const l = lines[i];
    if (!l) continue;
    const c = l[0];
    if (c === "{") { page = Number(l.slice(1)) || page + 1; stack.length = 0; continue; }
    if (c === "}") continue;
    if (c === "]" || c === ")") {
      const box = stack.pop();
      if (box && box.row) {
        const r = box.row;
        // Quelle der Zeile: was am häufigsten vorkommt (ohne die Zeile der Box selbst, die oft der Absatzanfang ist)
        let best = null, bestN = 0, all = 0;
        for (const [k, n] of box.counts) { all += n; if (n > bestN) { best = k; bestN = n; } }
        r.n = all; // wie viel darin steht (0: leere Kopfzeile o. Ä.)
        if (best) { const [t, ln] = best.split(":").map(Number); r.tag = t; r.line = ln; }
        rows.push(r);
      }
      continue;
    }
    const m = /^.(\d+),(\d+):(-?\d+),(-?\d+)(?::(-?\d+),(-?\d+),(-?\d+))?/.exec(l);
    if (!m) {
      if (l.startsWith("Postamble:")) break;
      continue;
    }
    const tag = Number(m[1]), line = Number(m[2]), v = Number(m[4]);
    if (c === "[" || c === "(") {
      const parent = stack[stack.length - 1];
      let row = null;
      // Eine Zeile: eine hbox direkt in einer vbox (oder auf der Seite), mit Breite
      if (c === "(" && (!parent || parent.kind === "[") && Number(m[5]) > 0) {
        const H = Number(m[6]) || 0, D = Number(m[7]) || 0;
        row = { page, v: toBP(v), top: toBP(v - H), bottom: toBP(v + D), tag, line };
      }
      // Liegt die Box in einer Zeile, zählt ihr Inhalt für diese Zeile
      const owner = row ? null : parent && (parent.row ? parent : parent.owner);
      stack.push({ kind: c, row, counts: new Map(), owner: owner || null });
      continue;
    }
    // Blätter: Zeichen, Kerne, Leim, Mathe, Regeln
    if ("xkg$r".includes(c)) {
      const top = stack[stack.length - 1];
      const target = top && (top.row ? top : top.owner);
      if (target) {
        const k = `${tag}:${line}`;
        target.counts.set(k, (target.counts.get(k) || 0) + 1);
      }
    }
  }
  rows.sort((a, b) => a.page - b.page || a.v - b.v);
  return { inputs, rows };
}

export function readSynctex(file) {
  const buf = fs.readFileSync(file);
  return parseSynctex((file.endsWith(".gz") ? zlib.gunzipSync(buf) : buf).toString("utf8"));
}

// ---------- Unterschied alt → neu (Zeilen) ----------

/// Für jede alte Zeile (1-basiert) ihre neue Nummer: {line, changed}. Unverändert: changed false. Umgeschrieben oder
/// gelöscht: die erste Zeile der neuen Fassung dieser Stelle (bei reinem Löschen die Zeile danach), changed true.
export function lineMap(oldText, newText) {
  const a = oldText.split("\n"), b = newText.split("\n");
  const n = a.length, m = b.length;
  let pre = 0;
  while (pre < n && pre < m && a[pre] === b[pre]) pre++;
  let suf = 0;
  while (suf < n - pre && suf < m - pre && a[n - 1 - suf] === b[m - 1 - suf]) suf++;
  // Paare gleicher Zeilen in der Mitte (LCS; bei sehr großen Mitten nur eindeutige Zeilen)
  const A = a.slice(pre, n - suf), B = b.slice(pre, m - suf);
  const pairs = A.length * B.length <= 4_000_000 ? lcsPairs(A, B) : uniquePairs(A, B);
  const map = new Array(n + 1);
  for (let k = 0; k < pre; k++) map[k + 1] = { line: k + 1, changed: false };
  for (let k = 0; k < suf; k++) map[n - k] = { line: m - k, changed: false };
  // Mitte: gepaarte Zeilen unverändert, der Rest gehört zum Abschnitt bis zum nächsten Paar
  let ia = 0, ib = 0;
  const all = [...pairs, [A.length, B.length]];
  for (const [pa, pb] of all) {
    // alte Zeilen ia..pa-1 ersetzt durch neue ib..pb-1
    const target = (ib < pb ? ib : pb) + pre + 1; // erste neue Zeile oder die danach
    for (let k = ia; k < pa; k++) map[pre + k + 1] = { line: Math.min(target, m), changed: true };
    if (pa < A.length) map[pre + pa + 1] = { line: pre + pb + 1, changed: false };
    ia = pa + 1;
    ib = pb + 1;
  }
  return map;
}

function lcsPairs(A, B) {
  const n = A.length, m = B.length;
  if (!n || !m) return [];
  const w = m + 1;
  const L = new Uint32Array((n + 1) * w);
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      L[i * w + j] = A[i] === B[j] ? L[(i + 1) * w + j + 1] + 1 : Math.max(L[(i + 1) * w + j], L[i * w + j + 1]);
    }
  }
  const pairs = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (A[i] === B[j]) { pairs.push([i, j]); i++; j++; }
    else if (L[(i + 1) * w + j] >= L[i * w + j + 1]) i++;
    else j++;
  }
  return pairs;
}

function uniquePairs(A, B) {
  const count = (arr) => { const c = new Map(); arr.forEach((x, i) => c.set(x, c.has(x) ? -1 : i)); return c; };
  const ca = count(A), cb = count(B);
  const pairs = [];
  let lastB = -1;
  A.forEach((x, i) => {
    const ia = ca.get(x), ib = cb.get(x);
    if (ia === i && ib !== undefined && ib >= 0 && ib > lastB) { pairs.push([i, ib]); lastB = ib; }
  });
  return pairs;
}

// ---------- Striche gruppieren und verschieben ----------

/// Rahmen eines Strichs (Seitenpunkte der App) aus seinen Punkten
export function strokeBox(wire) {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const p of wire.p || []) {
    const r = Math.max(Number(p[3]) || 0, 0) / 2;
    x0 = Math.min(x0, p[0] - r); x1 = Math.max(x1, p[0] + r);
    y0 = Math.min(y0, p[1] - r); y1 = Math.max(y1, p[1] + r);
  }
  return x0 <= x1 ? { x0, y0, x1, y1 } : null;
}

/// Striche, die sich (mit etwas Luft) berühren, bilden eine Gruppe: ein Wort, eine Formel, ein Pfeil. Eine Gruppe wird
/// immer als Ganzes verschoben, sonst risse ein Wort, dessen Unterlänge in die nächste Zeile reicht, auseinander.
export function groupStrokes(items, pad = 7) {
  const parent = items.map((_, i) => i);
  const find = (i) => { while (parent[i] !== i) { parent[i] = parent[parent[i]]; i = parent[i]; } return i; };
  const order = items.map((_, i) => i).sort((p, q) => items[p].box.y0 - items[q].box.y0);
  // Durch die nach oben sortierten Striche laufen; verglichen wird nur mit denen, die noch nicht weiter oben enden
  const active = [];
  for (const i of order) {
    const b = items[i].box;
    for (let k = active.length - 1; k >= 0; k--) {
      const j = active[k];
      const c = items[j].box;
      if (c.y1 + pad < b.y0 - pad) { active.splice(k, 1); continue; }
      if (c.x0 - pad <= b.x1 + pad && b.x0 - pad <= c.x1 + pad) parent[find(i)] = find(j);
    }
    active.push(i);
  }
  const groups = new Map();
  items.forEach((it, i) => {
    const r = find(i);
    if (!groups.has(r)) groups.set(r, []);
    groups.get(r).push(it);
  });
  return [...groups.values()];
}

/// Lage der Seiten in der App: je Seite {top, scale} (Seitenpunkte der App je bp)
export function pageFrames(pages) {
  const frames = [];
  let y = PAGE_GAP;
  for (const { width, height } of pages) {
    const scale = PAGE_WIDTH / width;
    frames.push({ top: y, scale, height: height * scale });
    y += height * scale + PAGE_GAP;
  }
  return frames;
}

/// Wohin jede Gruppe rückt. old/neu: {sync (parseSynctex), frames (pageFrames), files: tag → relativer Pfad},
/// maps: relativer Pfad → lineMap. Ergebnis: [{items, dy, changed}] nur für Gruppen, die sich bewegen (|dy| ≥ 0,5)
/// oder deren Zeile umgeschrieben wurde.
export function planMoves(groups, old, neu, maps) {
  const docRows = (side) => side.sync.rows
    .filter((r) => side.files.has(r.tag) && side.frames[r.page - 1])
    .map((r) => {
      const f = side.frames[r.page - 1];
      return { ...r, file: side.files.get(r.tag), y: f.top + r.v * f.scale, y0: f.top + r.top * f.scale,
        y1: f.top + r.bottom * f.scale };
    });
  const oldRows = docRows(old), newRows = docRows(neu);
  // Zeilen je Quellzeile, in Lesereihenfolge (eine lange Quellzeile ergibt mehrere gesetzte Zeilen)
  const byLine = (rows) => {
    const m = new Map();
    for (const r of rows) {
      const k = `${r.file}\n${r.line}`;
      if (!m.has(k)) m.set(k, []);
      m.get(k).push(r);
    }
    return m;
  };
  const oldBy = byLine(oldRows), newBy = byLine(newRows);
  const moves = [];
  if (!oldRows.length) return moves;
  for (const items of groups) {
    let y0 = Infinity, y1 = -Infinity;
    for (const it of items) { y0 = Math.min(y0, it.box.y0); y1 = Math.max(y1, it.box.y1); }
    const yc = (y0 + y1) / 2;
    // Die Zeile, in der die Mitte der Gruppe liegt, sonst die nächste darüber, sonst die erste
    let row = null;
    for (const r of oldRows) {
      if (r.y0 <= yc) row = r;
      else break;
    }
    if (!row) row = oldRows[0];
    const map = maps.get(row.file);
    if (!map) continue; // Datei unverändert gelesen: Lage gleich, außer sie rückt durch andere Dateien
    const target = map[row.line] || { line: row.line, changed: false };
    // Neue Zeile suchen; fehlt sie im Satz (etwa eine Leerzeile), die nächste gesetzte danach
    let candidates = newBy.get(`${row.file}\n${target.line}`);
    if (!candidates) {
      const later = newRows.filter((r) => r.file === row.file && r.line >= target.line).sort((p, q) => p.line - q.line);
      if (later.length) candidates = newBy.get(`${row.file}\n${later[0].line}`);
    }
    if (!candidates) continue;
    const siblings = oldBy.get(`${row.file}\n${row.line}`) || [row];
    const k = target.changed ? 0 : Math.min(Math.max(siblings.indexOf(row), 0), candidates.length - 1);
    const dy = candidates[k].y - row.y;
    if (Math.abs(dy) >= 0.5 || target.changed) moves.push({ items, dy: Math.round(dy * 100) / 100, changed: target.changed });
  }
  return moves;
}

// IDs wie im Browser (viewer.html: strokeID): SHA-256 über Tintenart und die ersten neun Werte je Punkt
function swiftNumber(v) {
  if (Object.is(v, -0)) return "-0.0";
  return Number.isInteger(v) ? v.toFixed(1) : String(v);
}
export function strokeID(wire) {
  const geometry = JSON.stringify([wire.ink, ...wire.p.map((p) => p.slice(0, 9).map(swiftNumber).join(","))]);
  return createHash("sha256").update(geometry).digest().subarray(0, 12).toString("hex");
}
/// Wie viewer.html (shifted): Punkte verschieben; ein Strich aus der App (pk) bekommt die Verschiebung als dx/dy dazu
export function shifted(wire, dx, dy) {
  const r = (v) => Math.round(v * 100) / 100;
  return {
    ...wire,
    ...(wire.pk ? { dx: r((wire.dx || 0) + dx), dy: r((wire.dy || 0) + dy) } : {}),
    p: wire.p.map((q) => [r(q[0] + dx), r(q[1] + dy), ...q.slice(2)]),
  };
}

// ---------- Projekte und Dokumente ----------

const SOURCE_EXT = new Set([".tex", ".bib", ".sty", ".cls", ".bst", ".png", ".jpg", ".jpeg", ".pdf", ".eps", ".tikz"]);

/// Projektordner: direkte Unterordner der Wurzeln mit einer notizbuch.json
export function findProjects(roots) {
  const out = [];
  for (const root of roots) {
    let entries = [];
    try { entries = fs.readdirSync(root, { withFileTypes: true }); } catch { continue; }
    for (const e of entries) {
      if (!e.isDirectory() || e.name.startsWith(".")) continue;
      const dir = path.join(root, e.name);
      const file = path.join(dir, "notizbuch.json");
      if (!fs.existsSync(file)) continue;
      let cfg = {};
      try { cfg = JSON.parse(fs.readFileSync(file, "utf8")); } catch { cfg = { kaputt: true }; }
      out.push({ dir, name: e.name, folder: String(cfg.ordner || e.name).slice(0, 80), files: cfg.dateien, cfg });
    }
  }
  return out;
}

/// Haupt-.tex eines Projekts: die in notizbuch.json genannten, sonst jede .tex direkt im Ordner mit \documentclass
export function mainFiles(project) {
  if (Array.isArray(project.files)) return project.files.filter((f) => typeof f === "string" && f.endsWith(".tex"));
  let names = [];
  try { names = fs.readdirSync(project.dir); } catch { return []; }
  return names.filter((n) => n.endsWith(".tex") && !n.startsWith(".")).filter((n) => {
    try {
      const head = fs.readFileSync(path.join(project.dir, n), "utf8").slice(0, 20000);
      return /^[^%\n]*\\documentclass/m.test(head);
    } catch { return false; }
  }).sort();
}

/// Die Quelldateien, die ein Lauf gelesen hat und die im Projekt liegen (aus der .fls von latexmk), relativ
export function projectInputs(flsText, projectDir) {
  const out = new Set();
  let pwd = projectDir;
  for (const l of flsText.split("\n")) {
    if (l.startsWith("PWD ")) pwd = l.slice(4).trim();
    if (!l.startsWith("INPUT ")) continue;
    const p = path.resolve(pwd, l.slice(6).trim());
    const rel = path.relative(projectDir, p);
    if (rel.startsWith("..") || path.isAbsolute(rel) || rel.startsWith(".notizbuch")) continue;
    if (SOURCE_EXT.has(path.extname(rel).toLowerCase())) out.add(rel);
  }
  return [...out].sort();
}

/// Fingerabdruck der Quellen: Größe und Zeit jeder Datei (billig; geändert heißt: neu setzen und den Inhalt vergleichen)
export function stamp(dir, files) {
  return files.map((f) => {
    try { const s = fs.statSync(path.join(dir, f)); return `${f}:${s.size}:${s.mtimeMs}`; } catch { return `${f}:-`; }
  }).join("|");
}

function hashFiles(dir, files) {
  const h = createHash("sha256");
  for (const f of files) {
    h.update(f + "\0");
    try { h.update(fs.readFileSync(path.join(dir, f))); } catch { h.update("-"); }
  }
  return h.digest("hex");
}

/// Maße aus der .aux (\nb@seite{Breite/Höhe} in pt) und Seitenzahl aus SyncTeX → [{width, height}] in bp
export function pagesFromAux(auxText, pageCount) {
  const m = /\\gdef\s*\\nb@seite\s*\{([\d.]+)pt\/([\d.]+)pt\}/.exec(auxText);
  if (!m) return null;
  const width = Number(m[1]) * PT_TO_BP, height = Number(m[2]) * PT_TO_BP;
  return Array.from({ length: Math.max(pageCount, 1) }, () => ({ width, height }));
}

/// Kurzfassung eines Fehlers aus der .log (die ersten Meldungen mit „!“ oder Datei:Zeile:)
export function logErrors(logText) {
  const lines = logText.split("\n");
  const out = [];
  for (let i = 0; i < lines.length && out.length < 6; i++) {
    if (/^!|^[^\s:]+\.tex:\d+:/.test(lines[i])) out.push(lines.slice(i, i + 3).join("\n").trim());
  }
  return out.join("\n\n");
}

/// Wo im A4-Satz jede Seite ab der zweiten beginnt, übertragen auf die lange Seite: [{page (A4-Seitennummer), y (pt ab
/// Oberkante der langen Seite)}]. Gleiche Satzbreite heißt gleiche Zeilenumbrüche: die k-te gesetzte Zeile einer
/// Quellzeile ist in beiden Sätzen dieselbe.
export function pageStarts(a4, long, projectDir) {
  const inProject = (sync) => {
    const files = new Map();
    for (const [tag, p] of sync.inputs) {
      const rel = path.relative(projectDir, path.resolve(projectDir, p));
      if (!rel.startsWith("..") && !path.isAbsolute(rel) && !rel.startsWith(".notizbuch")) files.set(tag, rel);
    }
    return sync.rows.filter((r) => files.has(r.tag)).map((r) => ({ ...r, file: files.get(r.tag) }));
  };
  const ordinals = (rows) => {
    const n = new Map();
    return rows.map((r) => {
      const k = `${r.file}\n${r.line}`;
      const i = n.get(k) || 0;
      n.set(k, i + 1);
      return { ...r, key: `${k}\n${i}` };
    });
  };
  // Ohne leere Zeilen (Kopfzeilen) und ohne Fußzeilen: die letzte Zeile einer Seite, wenig Inhalt, mit Abstand darüber
  const body = (rows) => {
    const out = rows.filter((r) => r.n > 0);
    return out.filter((r, i) => {
      const next = out[i + 1], prev = out[i - 1];
      const last = !next || next.page !== r.page;
      return !(last && r.n <= 6 && prev && prev.page === r.page && r.top - prev.bottom > 15);
    });
  };
  const a = ordinals(body(inProject(a4))), l = ordinals(body(inProject(long).filter((r) => r.page === 1)));
  const byKey = new Map(l.map((r) => [r.key, r]));
  const out = [];
  const pages = Math.max(0, ...a.map((r) => r.page));
  for (let p = 2; p <= pages; p++) {
    const first = a.find((r) => r.page === p);
    const hit = first && byKey.get(first.key);
    if (hit) out.push({ page: p, y: Math.max(0, hit.top / PT_TO_BP - 3) });
  }
  return out;
}

export function marksTeX(starts) {
  // Wird mitten im Dokument gelesen, wo @ kein Buchstabe ist
  return `\\makeatletter\\gdef\\nb@allemarken{${starts.map((s) => `\\nb@m{${s.y.toFixed(2)}}{${s.page}}`).join("")}}\\makeatother\n`;
}

// ---------- Der Teil mit Zustand ----------

export function create({ api, upload, log, getConfig, now = Date.now, run = runFile }) {
  const busy = new Set(); // Dokumente, die gerade gesetzt werden (Schlüssel: Projektordner + Datei)
  const watched = new Map(); // Schlüssel → {stamp, since}
  let timer = null;

  const cfg = () => {
    const c = getConfig().latex || {};
    const home = os.homedir();
    // Ein Helfer mit eigenem Arbeitsordner (Tests) setzt nur, wenn seine config.json „latex“ nennt
    const test = !!process.env.BETTERNOTES_HELFER_HOME && !getConfig().latex;
    return {
      on: c.an !== false && !test,
      roots: (c.wurzeln || [path.join(home, "Documents", "ClaudeCode")]).map((r) => r.replace(/^~(?=$|\/)/, home)),
      texbin: c.texbin || "/Library/TeX/texbin",
      seconds: c.sekunden || 3,
      quiet: c.ruhe || 2,
    };
  };

  function docDir(project, file) {
    return path.join(project.dir, ".notizbuch", file.replace(/\.tex$/, ""));
  }
  function readJSON(file, fallback) {
    try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return fallback; }
  }
  function writeJSON(file, value) {
    fs.writeFileSync(file + ".tmp", JSON.stringify(value, null, 2));
    fs.renameSync(file + ".tmp", file);
  }

  /// latexmk im Projektordner. Ergebnis: {ok, pdf, synctex, aux, fls, log}
  async function compile(project, file) {
    const c = cfg();
    const dir = docDir(project, file);
    const out = path.join(dir, "bau");
    fs.mkdirSync(out, { recursive: true });
    fs.writeFileSync(path.join(project.dir, ".notizbuch", "nb-lang.tex"), PRETEX);
    const job = file.replace(/\.tex$/, "");
    const src = fs.readFileSync(path.join(project.dir, file), "utf8").slice(0, 3000);
    const engine = /%\s*!TEX\s+(?:TS-)?program\s*=\s*xelatex/i.test(src) ? "-xelatex"
      : /%\s*!TEX\s+(?:TS-)?program\s*=\s*lualatex/i.test(src) ? "-lualatex" : "-pdf";
    const env = { HOME: os.homedir(), PATH: `${c.texbin}:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`,
      LANG: "en_US.UTF-8" };
    const latexmk = (outdir, pretex, force = false) => run(path.join(c.texbin, "latexmk"), [engine, ...(force ? ["-g"] : []),
      "-synctex=1", "-interaction=nonstopmode",
      "-file-line-error", "-recorder", `-outdir=${path.relative(project.dir, outdir)}`, `-jobname=${job}`,
      ...(pretex ? [`-usepretex=${pretex}`] : []), file], { cwd: project.dir, env, timeout: 180000 });
    const read = (d, ext) => { try { return fs.readFileSync(path.join(d, job + ext), "utf8"); } catch { return ""; } };
    // Zuerst wie gewohnt auf A4 (das PDF zum Einreichen, und wo dort die Seiten beginnen), dann die lange Seite
    const a4dir = path.join(dir, "a4");
    fs.mkdirSync(a4dir, { recursive: true });
    const a4 = await latexmk(a4dir, null);
    const a4pdf = path.join(a4dir, job + ".pdf"), a4sync = path.join(a4dir, job + ".synctex.gz");
    const a4ok = a4.ok && fs.existsSync(a4pdf) && fs.existsSync(a4sync);
    const marks = path.relative(project.dir, path.join(dir, "marken.tex"));
    const pretex = `\\def\\nbMarken{${marks}}\\input{.notizbuch/nb-lang.tex}`;
    let res = await latexmk(out, pretex);
    const pdf = path.join(out, job + ".pdf"), synctex = path.join(out, job + ".synctex.gz");
    // Die Linien: Lage aus diesem Satz; ändern sie sich, noch ein Lauf (sie verschieben nichts, sie liegen im Hintergrund)
    if (res.ok && a4ok && fs.existsSync(synctex)) {
      const text = marksTeX(pageStarts(readSynctex(a4sync), readSynctex(synctex), project.dir));
      let before = null;
      try { before = fs.readFileSync(path.join(dir, "marken.tex"), "utf8"); } catch {}
      if (before !== text) {
        fs.writeFileSync(path.join(dir, "marken.tex"), text);
        res = await latexmk(out, pretex, true); // latexmk kennt marken.tex beim ersten Mal noch nicht als Quelle
      }
    }
    const logText = read(out, ".log");
    const ok = res.ok && fs.existsSync(pdf) && fs.existsSync(synctex);
    return { ok, pdf, synctex, aux: read(out, ".aux"), fls: read(out, ".fls"), log: logText, a4pdf: a4ok ? a4pdf : null,
      a4pages: a4ok ? Math.max(1, ...readSynctex(a4sync).rows.map((x) => x.page)) : 0,
      error: ok ? "" : (logErrors(logText) || res.output.slice(-1500)) };
  }

  /// Alle Striche eines Dokuments (mit PencilKit-Original), in Server-Reihenfolge
  async function strokes(doc) {
    const out = new Map();
    let since = 0, top = 0;
    for (let guard = 0; guard < 400; guard++) {
      const r = (await api("GET", `/api/doc/${doc}/strokes?since=${since}&limit=1000`)).data;
      top = Math.max(top, r.top || 0);
      for (const ch of r.changes || []) {
        if (ch.data) out.set(ch.id, ch.data);
        else out.delete(ch.id);
      }
      since = r.last;
      if (!r.more) break;
    }
    return { strokes: out, top };
  }

  /// Setzt ein Dokument neu und tauscht es im Notizbuch aus. Grund: für das Protokoll
  async function build(project, file, why) {
    const key = path.join(project.dir, file);
    if (busy.has(key)) return { skipped: true };
    busy.add(key);
    try {
      const dir = docDir(project, file);
      fs.mkdirSync(dir, { recursive: true });
      const zustandFile = path.join(dir, "zustand.json");
      const zustand = readJSON(zustandFile, {});
      const t0 = now();
      const r = await compile(project, file);
      const inputs = r.fls ? projectInputs(r.fls, project.dir) : [file];
      watched.set(key, { stamp: stamp(project.dir, inputs), inputs });
      if (!r.ok) {
        fs.writeFileSync(path.join(dir, "fehler.txt"), r.error || "Setzen fehlgeschlagen");
        log(`LaTeX: ${project.name}/${file} lässt sich nicht setzen (${why})`);
        return { ok: false, error: r.error };
      }
      try { fs.rmSync(path.join(dir, "fehler.txt")); } catch {}
      // Das A4-PDF zum Einreichen neben die .tex (gleicher Name)
      if (r.a4pdf) {
        try { fs.copyFileSync(r.a4pdf, path.join(project.dir, file.replace(/\.tex$/, ".pdf"))); } catch {}
      }
      const hash = hashFiles(project.dir, inputs) + ":" + createHash("sha256").update(fs.readFileSync(r.pdf)).digest("hex");
      if (zustand.hash === hash && zustand.doc) return { ok: true, unchanged: true };
      const sync = readSynctex(r.synctex);
      const pageCount = Math.max(1, ...sync.rows.map((x) => x.page));
      const pages = pagesFromAux(r.aux, pageCount);
      if (!pages) throw new Error("Seitenmaße fehlen in der .aux (nb-lang.tex nicht geladen?)");
      const files = new Map();
      for (const [tag, p] of sync.inputs) {
        const rel = path.relative(project.dir, path.resolve(project.dir, p));
        if (!rel.startsWith("..") && !path.isAbsolute(rel) && !rel.startsWith(".notizbuch")) files.set(tag, rel);
      }
      const neu = { sync, frames: pageFrames(pages), files };

      // Dokument im Notizbuch: anlegen oder finden
      const lib = (await api("GET", "/api/library")).data.docs || [];
      let meta = zustand.doc && lib.find((d) => d.id === zustand.doc);
      if (meta && meta.deleted) meta = null; // in der App gelöscht: neu anlegen
      const title = file.replace(/\.tex$/, "");
      const nowS = now() / 1000;
      const version = Math.max(now(), (meta?.pagesVersion || 0) + 1, (meta?.pdfVersion || 0) + 1);
      let moved = 0, changed = 0;
      if (!meta) {
        const id = randomUUID().toUpperCase();
        await upload(`/api/pdf/${id}`, fs.readFileSync(r.pdf));
        meta = { id, title, kind: "pdf", created: nowS, modified: nowS, pageCount, layoutVersion: 2,
          folder: project.folder, pdfVersion: version, pagesVersion: version };
        await api("PUT", `/api/library/${id}`, { json: meta });
        log(`LaTeX: ${project.name}/${file} neu im Notizbuch (${pageCount} S., ${Math.round((now() - t0) / 1000)} s, ${why})`);
      } else {
        // Striche verschieben: alter Stand (stand/) gegen neuen
        const oldSync = fs.existsSync(path.join(dir, "stand", "synctex.gz")) ? readSynctex(path.join(dir, "stand", "synctex.gz")) : null;
        let plan = [];
        let all = null;
        if (oldSync && zustand.pages) {
          const oldFiles = new Map();
          for (const [tag, p] of oldSync.inputs) {
            const rel = path.relative(project.dir, path.resolve(project.dir, p));
            if (!rel.startsWith("..") && !path.isAbsolute(rel) && !rel.startsWith(".notizbuch")) oldFiles.set(tag, rel);
          }
          const maps = new Map();
          for (const rel of new Set([...oldFiles.values()])) {
            let before = null, after = "";
            try { before = fs.readFileSync(path.join(dir, "stand", "quellen", rel), "utf8"); } catch {}
            try { after = fs.readFileSync(path.join(project.dir, rel), "utf8"); } catch {}
            if (before !== null) maps.set(rel, lineMap(before, after));
          }
          all = await strokes(meta.id);
          const items = [];
          for (const [id, data] of all.strokes) {
            let wire;
            try { wire = JSON.parse(data); } catch { continue; }
            const box = wire && wire.p ? strokeBox(wire) : null;
            if (box) items.push({ id, wire, box });
          }
          plan = planMoves(groupStrokes(items), { sync: oldSync, frames: pageFrames(zustand.pages), files: oldFiles }, neu, maps);
        }
        // Erst das PDF, dann der Seitenstand: Geräte holen bei der neuen pdfVersion das neue PDF
        await upload(`/api/pdf/${meta.id}`, fs.readFileSync(r.pdf));
        const next = { ...meta, modified: Math.max(nowS, (meta.modified || 0) + 0.01), pageCount, pdfVersion: version,
          pagesVersion: version };
        delete next.strokeSeq;
        delete next.hasPDF;
        await api("PUT", `/api/library/${meta.id}`, { json: next });
        if (plan.length) {
          const add = [], remove = [];
          const taken = new Set(all.strokes.keys());
          for (const mv of plan) {
            if (mv.changed) changed += mv.items.length;
            if (Math.abs(mv.dy) < 0.5) continue;
            for (const it of mv.items) {
              const wire = shifted(it.wire, 0, mv.dy);
              let id = strokeID(wire);
              while (taken.has(id)) id += "#2";
              taken.add(id);
              remove.push(it.id);
              add.push({ id, data: JSON.stringify(wire) });
              moved++;
            }
          }
          for (let k = 0; k < add.length; k += 300) {
            await api("POST", `/api/doc/${meta.id}/sync`, {
              json: { since: all.top, add: add.slice(k, k + 300), remove: remove.slice(k, k + 300) } });
          }
        }
        log(`LaTeX: ${project.name}/${file} neu gesetzt (${pageCount} S., ${moved} Striche verschoben, ${changed} an ` +
          `umgeschriebenen Stellen, ${Math.round((now() - t0) / 1000)} s, ${why})`);
      }
      // Stand festhalten: Quellen und SyncTeX dieses PDFs
      const stand = path.join(dir, "stand");
      fs.rmSync(stand + ".neu", { recursive: true, force: true });
      fs.mkdirSync(path.join(stand + ".neu", "quellen"), { recursive: true });
      for (const rel of new Set([...files.values(), ...inputs.filter((f) => f.endsWith(".tex"))])) {
        const to = path.join(stand + ".neu", "quellen", rel);
        fs.mkdirSync(path.dirname(to), { recursive: true });
        try { fs.copyFileSync(path.join(project.dir, rel), to); } catch {}
      }
      fs.copyFileSync(r.synctex, path.join(stand + ".neu", "synctex.gz"));
      fs.rmSync(stand, { recursive: true, force: true });
      fs.renameSync(stand + ".neu", stand);
      writeJSON(zustandFile, { doc: meta.id, hash, pages, version, gesetzt: new Date(now()).toISOString() });
      return { ok: true, doc: meta.id, moved, changed };
    } finally {
      busy.delete(key);
    }
  }

  /// Ein Durchgang: Projekte suchen, geänderte Dokumente (Quellen ruhig seit `quiet` s) neu setzen
  async function tick() {
    const c = cfg();
    if (!c.on) return;
    for (const project of findProjects(c.roots)) {
      for (const file of mainFiles(project)) {
        const key = path.join(project.dir, file);
        if (busy.has(key)) continue;
        const w = watched.get(key);
        const zustand = readJSON(path.join(docDir(project, file), "zustand.json"), null);
        const inputs = w ? w.inputs : [file];
        const s = stamp(project.dir, inputs);
        if (w && w.stamp === s && zustand) continue;
        // Erst wenn sich eine Weile nichts mehr ändert (Claude schreibt oft mehrere Dateien nacheinander)
        const pending = w && w.pending;
        if (!pending || pending.stamp !== s) {
          watched.set(key, { ...(w || { inputs }), pending: { stamp: s, since: now() } });
          if (w || zustand) continue;
        } else if (now() - pending.since < c.quiet * 1000) continue;
        try {
          await build(project, file, w ? "geändert" : "Start");
        } catch (e) {
          log(`LaTeX: ${project.name}/${file}: ${e.message}`);
          watched.set(key, { inputs, stamp: s });
        }
      }
    }
  }

  function start() {
    if (timer) return;
    const loop = async () => {
      try { await tick(); } catch (e) { log("LaTeX:", e.message); }
      timer = setTimeout(loop, cfg().seconds * 1000);
    };
    timer = setTimeout(loop, 1000);
  }

  return { start, tick, build, compile };
}

function runFile(bin, args, { cwd, env, timeout }) {
  return new Promise((resolve) => {
    execFile(bin, args, { cwd, env, timeout, maxBuffer: 20 * 1024 * 1024 }, (err, stdout, stderr) => {
      resolve({ ok: !err, output: `${stdout || ""}${stderr || ""}` });
    });
  });
}
