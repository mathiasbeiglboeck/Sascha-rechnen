// BetterNotes – „Weitere Seiten zum Nachlesen“ für den Helfer (helfer.mjs lädt es mit import(); fehlt es oder geht es
// nicht, läuft alles wie bisher). Fragt Mathias zu einer Stelle, entscheidet Claude selbst, ob es weitere Seiten
// desselben Dokuments braucht: Der Helfer hält je Dokument einen Spiegel der Striche vom Server (nur lesend, in
// Stücken ab dem letzten Stand), zeichnet daraus jede weitere beschriebene Seite als einseitiges PDF (wie die
// Nachbarseiten der App: oben „Seite N“, darunter Karos oder die PDF-Seite, darauf die Striche) und legt sie neben die
// Frage: fragen/<id>/weitere/seite-<N>.pdf. Claude liest davon mit Read, was es braucht.
//
// Spiegel (spiegel/), gezeichnete Seiten (seitenbilder/) und das Skript für die PDF-Hintergründe (hintergrund.js)
// liegen außerhalb von chats/; in den Chat-Ordner kommen nur Kopien, nie Verweise. Den Schlüssel des Servers bringt
// api() selbst mit, hier kommt er nicht vor. Notizbücher brauchen kein macOS-Skript, nur PDFs (für den Hintergrund).

import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";

// Seitenmaße der App in Seitenpunkten (Layout-Version 2, PageLayout.swift): 768 breit, untereinander mit 6 Abstand;
// Karos 768/30 (PageView.gridStep); der Streifen „Seite N“ über jeder Seite 44 hoch (AskCapture.contextPDF)
export const LAYOUT = { W: 768, GAP: 6, A4H: 768 * 297 / 210, GRID: 768 / 30, BAND: 44 };
// Neue Nummer, wenn sich das Zeichnen ändert: Dann zeichnet der Helfer jede Seite neu
export const RENDER_VERSION = 1;
// Einstellungen in config.json (helfer.mjs mischt sie mit diesen)
export const DEFAULTS_WEITERE = {
  // Höchstens so viele weitere Seiten liest Claude je Frage; 0: aus
  morePages: { quick: 6, thorough: 20 },
  // So lange (Sekunden ab dem Übernehmen der Frage) darf das Vorbereiten dauern; was bis dahin nicht gezeichnet ist,
  // gibt es zu dieser Frage nicht
  morePagesSeconds: { quick: 15, thorough: 40 },
  // Höchstens so viele gelesene Zeilen am Server je Tag (UTC) für den Spiegel; der Gratis-Tarif erlaubt 5 Millionen
  // für alles zusammen
  mirrorRowsPerDay: 250000,
};

// Fehler des Macs selbst (etwa die Platte voll): gehen an den Helfer weiter, wie bei den anderen Dateien zur Frage
const LOCAL_ERRORS = new Set(["ENOSPC", "EDQUOT", "EROFS", "EACCES", "EPERM", "ENOTDIR", "EISDIR", "EIO", "EMFILE", "ENFILE"]);
const DOC_ID = /^[A-Za-z0-9-]{1,64}$/;
const MARKER_INK = "com.apple.ink.marker";
const MAX_OFFER = 200; // so viele Seiten bietet eine Frage höchstens an (die nächsten zuerst)
const PULL_LIMIT = 500; // Striche je Abruf
const PULL_GAP_MS = 150; // Pause zwischen zwei Abrufen: Der Abgleich der Geräte geht vor
const NO_ROUTE_MS = 10 * 60000; // Server ohne die Route: so lange nicht mehr fragen (wie bei den Fragen)
const TWIN_MS = 30 * 60000; // Zwillinge nach einer Seitenänderung zählen nur so lange danach
const BG_BATCH = 8; // PDF-Hintergründe je Aufruf von osascript
const MAX_PAGES = 10000; // mehr Seiten nimmt der Spiegel nicht an (unsinnige Koordinaten)
const DAY = 86400000;
const HOUR = 3600000;
const WEEK = 7 * DAY;

const sha1 = (s) => createHash("sha1").update(s).digest("hex");
const r2 = (v) => Math.round(v * 100) / 100;
const r3 = (v) => Math.round(v * 1000) / 1000;
const isNum = (v) => typeof v === "number" && Number.isFinite(v);

// ---------- Striche, Seiten ----------

/// Ein Strich vom Server (JSON wie StrokeCodec.wire, ohne pk) kurz gefasst: {k: Tinte, c: [r, g, b, a] (0…1),
/// p: [x, y, w, x, y, w, …] (Seitenpunkte, w die gezeichnete Breite wie in viewer.html), b: [x0, y0, x1, y1] (Punkte
/// ± halbe Breite), s: Kennzahl aus Tinte, Farbe, Punktzahl und allen x (für Zwillinge)}. null, wenn er nicht taugt.
/// dx/dy gelten nur für pk: Die Punkte sind schon die aktuelle Lage
export function compactStroke(data) {
  let w;
  try {
    w = JSON.parse(data);
  } catch {
    return null;
  }
  const pts = w?.p;
  if (!Array.isArray(pts) || !pts.length || pts.length > 20000) return null;
  const k = typeof w.ink === "string" ? w.ink.slice(0, 100) : "";
  const col = Array.isArray(w.c) ? w.c : [];
  const unit = (v, d) => (isNum(v) ? Math.min(1, Math.max(0, r3(v))) : d);
  const c = [unit(col[0], 0), unit(col[1], 0), unit(col[2], 0), unit(col[3], 1)];
  const p = new Array(pts.length * 3);
  const xs = new Array(pts.length);
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity, wmax = 0;
  for (let i = 0; i < pts.length; i++) {
    const q = pts[i];
    if (!Array.isArray(q) || q.length < 9) return null;
    for (let j = 0; j < Math.min(q.length, 10); j++) if (!isNum(q[j])) return null;
    // Gezeichnete Breite: Punkte aus der App tragen als 10. Wert die Zweitskala von PencilKit. 9 Werte: aus dem Browser
    // (Deckkraft 1, Druck 1, Azimut 0, Neigung 1,571, viewer.html) die Breite selbst; aus der App vor der Zweitskala
    // (4.–10.11.) zeichnete PencilKit sie bei Mathias etwa 0,69 + 0,22 × Breite dick (EditorView.swift), nie dicker
    const browser = q[5] === 1 && q[6] === 1 && q[7] === 0 && q[8] === 1.571;
    const x = r2(q[0]), y = r2(q[1]);
    const wd = r3(q.length > 9 ? q[3] * q[9] * 2 : browser ? q[3] : Math.min(q[3], 0.69 + 0.22 * q[3]));
    if (Math.abs(x) > 1e7 || Math.abs(y) > 1e7 || !(wd >= 0 && wd <= 1000)) return null;
    p[3 * i] = x;
    p[3 * i + 1] = y;
    p[3 * i + 2] = wd;
    xs[i] = x;
    if (x < x0) x0 = x;
    if (x > x1) x1 = x;
    if (y < y0) y0 = y;
    if (y > y1) y1 = y;
    if (wd > wmax) wmax = wd;
  }
  const h = wmax / 2;
  const b = [r2(x0 - h), r2(y0 - h), r2(x1 + h), r2(y1 + h)];
  const s = sha1(`${k}|${c.join(",")}|${pts.length}|${xs.join(",")}`).slice(0, 16);
  return { k, c, p, b, s };
}

/// Notizbuch: n A4-Seiten untereinander (mindestens eine), je {y, h} in Seitenpunkten
export function notebookFrames(n) {
  const { GAP, A4H } = LAYOUT;
  return Array.from({ length: Math.max(1, Math.floor(n) || 0) }, (_, i) => ({ y: GAP + i * (A4H + GAP), h: A4H }));
}

/// PDF: die Seitenhöhen (bei 768 Breite) untereinander wie PageLayout.stack
export function pdfFrames(heights) {
  const out = [];
  let y = LAYOUT.GAP;
  for (const h of heights) {
    out.push({ y, h });
    y += h + LAYOUT.GAP;
  }
  return out;
}

/// Wie viele Notizbuchseiten Tinte bis `bottom` braucht (eine leere zu viel schadet nicht)
function notebookPagesFor(bottom) {
  const { GAP, A4H } = LAYOUT;
  if (!(bottom > GAP)) return 1;
  return Math.min(MAX_PAGES, Math.max(1, Math.ceil((bottom - GAP) / (A4H + GAP))));
}

/// Erste Seite, deren Unterkante tiefer liegt als y (binäre Suche; die Seiten liegen der Reihe nach)
function firstFrame(frames, y) {
  let lo = 0, hi = frames.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (frames[mid].y + frames[mid].h > y) hi = mid;
    else lo = mid + 1;
  }
  return lo;
}

/// Seiten (Index ab 0), die ein Rechteck [x0, y0, x1, y1] senkrecht um mehr als 0,5 Punkte überdeckt oder ganz enthalten
/// (ein waagrechter Haarstrich ist keine 0,5 Punkte hoch)
function* pagesOf(b, frames) {
  for (let i = firstFrame(frames, b[1]); i < frames.length && frames[i].y < b[3]; i++) {
    const f = frames[i];
    if (Math.min(b[3], f.y + f.h) - Math.max(b[1], f.y) > 0.5 || (b[1] >= f.y && b[3] <= f.y + f.h)) yield i;
  }
}

/// Striche je Seite: Map Index (ab 0) → Striche in der gegebenen Reihenfolge (seq). Ein Strich gehört zu jeder Seite,
/// die er senkrecht um mehr als 0,5 Punkte überdeckt (wie PDFExport, ein Strich über die Seitengrenze auf beide), und
/// zu der, in der er ganz liegt. Unter der letzten Seite fällt Tinte weg (PDF); mit `grow` (Notizbuch) kommen so viele
/// Seiten dazu, wie die Tinte braucht
export function inkByPage(strokes, frames, { grow = false } = {}) {
  let fr = frames;
  if (grow) {
    let bottom = -Infinity;
    for (const st of strokes) if (st.b[3] > bottom) bottom = st.b[3];
    const need = notebookPagesFor(bottom);
    if (need > fr.length) fr = notebookFrames(need);
  }
  const out = new Map();
  for (const st of strokes) {
    for (const i of pagesOf(st.b, fr)) {
      const list = out.get(i);
      if (list) list.push(st);
      else out.set(i, [st]);
    }
  }
  return out;
}

/// Nach einer Seitenänderung lädt die App jeden Strich darunter verschoben und mit neuer ID hinauf und löscht die alten
/// erst mit dem letzten Stück (je 300 Striche): Eine Weile gibt es beide („Zwillinge“). Gibt die erste Seite (Index ab
/// 0) zurück, ab der das gerade geschieht, sonst null. Zwillinge: gleiche Kennzahl s, in seq-Reihenfolge benachbart,
/// mindestens 300 Punkte senkrecht auseinander; erst ab drei Paaren mit gleichem (gerundetem) Abstand. Nur bis 30 Minuten
/// nach der Seitenänderung (pagesVersion, ms): Eine absichtlich kopierte Zeichnung soll keine Seiten auf Dauer verbergen
export function movingFrom(strokes, frames, { pagesVersion, now }) {
  const pv = Number(pagesVersion) || 0;
  if (!pv || !(now - pv <= TWIN_MS)) return null;
  const groups = new Map();
  for (const st of strokes) {
    const g = groups.get(st.s);
    if (g) g.push(st);
    else groups.set(st.s, [st]);
  }
  const byDy = new Map();
  for (const g of groups.values()) {
    for (let i = 1; i < g.length; i++) {
      const dy = Math.round(g[i].b[1] - g[i - 1].b[1]);
      if (Math.abs(dy) < 300) continue;
      const list = byDy.get(dy);
      if (list) list.push(g[i - 1], g[i]);
      else byDy.set(dy, [g[i - 1], g[i]]);
    }
  }
  let low = null;
  for (const list of byDy.values()) {
    if (list.length < 6) continue;
    for (const st of list) {
      for (const i of pagesOf(st.b, frames)) {
        if (low === null || i < low) low = i;
        break;
      }
    }
  }
  return low;
}

/// Welche beschriebenen Seiten Claude angeboten bekommt: alle außer der Frage, den schon gezeigten (covered) und denen
/// ab withheldFrom, die nächsten zur Frage zuerst (gleich weit: die davor zuerst), höchstens max; over: der Rest
export function chooseMore({ q, written, covered = [], withheldFrom = null, max = MAX_OFFER }) {
  const skip = new Set(covered);
  const list = [...new Set(written)].filter((i) => i !== q && !skip.has(i) && (withheldFrom == null || i < withheldFrom));
  list.sort((a, b) => Math.abs(a - q) - Math.abs(b - q) || a - b);
  return { offer: list.slice(0, max), over: list.slice(max) };
}

/// Aufeinanderfolgende Nummern als [von, bis], aufsteigend, ohne doppelte
function runsOf(numbers) {
  const list = [...new Set(numbers.map(Number))].filter(Number.isFinite).sort((a, b) => a - b);
  const runs = [];
  for (const n of list) {
    const r = runs.at(-1);
    if (r && n === r[1] + 1) r[1] = n;
    else runs.push([n, n]);
  }
  return runs;
}

/// Seitennummern (ab 1) für Claude: „Seite 9“, „die Seiten 1 bis 4, 9 und 20 bis 23“; mit `dative` „auf Seite 9“,
/// „auf den Seiten 1 bis 4, 9 und 20 bis 23“. Ab drei Seiten am Stück „a bis b“, sonst einzeln
export function pageRanges(numbers, dative = false) {
  const items = [];
  for (const [a, b] of runsOf(numbers)) {
    if (b - a >= 2) items.push(`${a} bis ${b}`);
    else for (let n = a; n <= b; n++) items.push(String(n));
  }
  if (!items.length) return "";
  if (items.length === 1 && !items[0].includes(" ")) return `${dative ? "auf " : ""}Seite ${items[0]}`;
  const list = items.length === 1 ? items[0] : `${items.slice(0, -1).join(", ")} und ${items.at(-1)}`;
  return `${dative ? "auf den" : "die"} Seiten ${list}`;
}

/// Kurz fürs Protokoll: „1–4, 9, 20–23“
export function pageRangesShort(numbers) {
  const items = [];
  for (const [a, b] of runsOf(numbers)) {
    if (b - a >= 2) items.push(`${a}–${b}`);
    else for (let n = a; n <= b; n++) items.push(String(n));
  }
  return items.join(", ");
}

// ---------- Eine Seite als PDF ----------

/// Größe einer Seite der Höhe h (Seitenpunkte) im PDF wie AskCapture.contextJPEG: Hochformat 1200 breit, Querformat
/// 1600, höchstens 2000 lang. s: Ausgabepunkte je Seitenpunkt, PW × PH: die Seite ohne den Streifen darüber
export function pageGeometry(h) {
  const { W } = LAYOUT;
  const s = Math.min((W > h ? 1600 : 1200) / W, 2000 / Math.max(W, h));
  return { s, PW: Math.round(W * s), PH: Math.round(h * s) };
}

/// Breite, Höhe und Farbkanäle eines JPEGs (aus seinem SOF-Abschnitt), sonst null
export function jpegInfo(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 4 || buf[0] !== 0xff || buf[1] !== 0xd8) return null;
  let i = 2;
  while (i + 4 <= buf.length) {
    if (buf[i] !== 0xff) return null;
    const m = buf[i + 1];
    if (m === 0xff) {
      i++;
      continue;
    }
    if (m === 0x01 || (m >= 0xd0 && m <= 0xd8)) {
      i += 2;
      continue;
    }
    if (m === 0xd9 || m === 0xda) return null;
    const len = buf.readUInt16BE(i + 2);
    if (len < 2) return null;
    if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) {
      if (i + 10 > buf.length) return null;
      const h = buf.readUInt16BE(i + 5), w = buf.readUInt16BE(i + 7), comps = buf[i + 9];
      return w && h && comps ? { w, h, comps } : null;
    }
    i += 2 + len;
  }
  return null;
}

/// Eine Seite als einseitiges PDF, wie die App ihre Nachbarseiten für Claude zeichnet (AskCapture.contextJPEG): oben
/// ein Streifen mit `label`, darunter die Seite (frame {y, h} in Seitenpunkten) mit Karos oder dem JPEG `jpeg` (der
/// PDF-Seite, genau PW × PH Pixel, unverändert eingebettet) und darauf die Striche (kurz gefasst, in seq-Reihenfolge).
/// Jeder Strich als Kurve durch die Mittelpunkte seiner Punkte (wie viewer.html), runde Enden, Breite je Abschnitt,
/// mindestens 1 Ausgabepunkt; ein einzelner Punkt als Kreis; Deckkraft unter 1 und Textmarker (Multiplizieren, damit
/// Gedrucktes darunter lesbar bleibt) über einen Grafikzustand. Alle Zahlen schreibt der Helfer selbst; aus den Strichen
/// kommt kein Text ins PDF
export function pagePDF({ frame, strokes = [], label = "", jpeg = null }) {
  const { W, GRID, BAND } = LAYOUT;
  const { s, PW, PH } = pageGeometry(frame.h);
  const H = PH + BAND;
  const fy = frame.y;
  const minW = 1 / s; // 1 Ausgabepunkt in Seitenpunkten
  // Koordinaten in Zehntel Seitenpunkten als ganze Zahlen (kürzer als Dezimalzahlen, genau genug)
  const N = (v) => String(Math.round(v * 10));
  const dec = (v, d) => String(Math.round(v * 10 ** d) / 10 ** d);
  const text = String(label).replace(/[^\x20-\x7e]/g, "?").replace(/[\\()]/g, "\\$&");
  let c = `0.9 g 0 ${PH} ${PW} ${BAND} re f\nBT /F1 22 Tf 0 g 16 ${H - 9 - 17} Td (${text}) Tj ET\n`;
  // Die Seite: abgeschnitten, weiß, Hintergrund, dann y nach unten und Zehntel Seitenpunkte ab der Seitenecke
  c += `q 0 0 ${PW} ${PH} re W n 1 g 0 0 ${PW} ${PH} re f\n`;
  let image = null;
  if (jpeg) {
    image = jpegInfo(jpeg);
    if (!image || (image.comps !== 1 && image.comps !== 3)) throw new Error("Hintergrund ist kein brauchbares JPEG");
    c += `q ${PW} 0 0 ${PH} 0 0 cm /Im1 Do Q\n`;
  }
  c += `${dec(s / 10, 7)} 0 0 ${dec(-s / 10, 7)} 0 ${PH} cm\n`;
  if (!jpeg) {
    // Karos wie PageView.drawGrid beim Export: 0,5 Punkte breit (mindestens 1 Ausgabepunkt), Linien bis an den Rand
    c += `0.82 G ${dec(Math.max(0.5, minW) * 10, 3)} w\n`;
    for (let k = 0; k * GRID <= W + 1e-6; k++) c += `${N(k * GRID)} 0 m ${N(k * GRID)} ${N(frame.h)} l\n`;
    for (let k = 0; k * GRID <= frame.h + 1e-6; k++) c += `0 ${N(k * GRID)} m ${N(W)} ${N(k * GRID)} l\n`;
    c += "S\n";
  }
  c += "1 J 1 j\n";
  const states = new Map(); // "Deckkraft|Textmarker" → Name des Grafikzustands
  let color = null; // Farbe außerhalb von q … Q
  for (const st of strokes) {
    const p = st.p, n = p.length / 3;
    if (!n) continue;
    const alpha = isNum(st.c?.[3]) ? Math.min(1, Math.max(0, st.c[3])) : 1;
    const marker = st.k === MARKER_INK;
    const rgb = [0, 1, 2].map((j) => dec(Math.min(1, Math.max(0, Number(st.c?.[j]) || 0)), 3)).join(" ");
    let wrap = false;
    if (alpha < 1 || marker) {
      const key = `${dec(alpha, 3)}|${marker ? 1 : 0}`;
      if (!states.has(key)) states.set(key, `G${states.size + 1}`);
      c += `q /${states.get(key)} gs ${rgb} RG ${rgb} rg\n`;
      wrap = true;
    } else if (rgb !== color) {
      c += `${rgb} RG ${rgb} rg\n`;
      color = rgb;
    }
    if (n === 1) {
      const r = Math.max(p[2] / 2, minW / 2), x = p[0], y = p[1] - fy, k = 0.5523 * r;
      c += `${N(x + r)} ${N(y)} m ${N(x + r)} ${N(y + k)} ${N(x + k)} ${N(y + r)} ${N(x)} ${N(y + r)} c ` +
        `${N(x - k)} ${N(y + r)} ${N(x - r)} ${N(y + k)} ${N(x - r)} ${N(y)} c ` +
        `${N(x - r)} ${N(y - k)} ${N(x - k)} ${N(y - r)} ${N(x)} ${N(y - r)} c ` +
        `${N(x + k)} ${N(y - r)} ${N(x + r)} ${N(y - k)} ${N(x + r)} ${N(y)} c f\n`;
    } else {
      // Kurve durch die Mittelpunkte, der Punkt dazwischen als Kontrollpunkt (quadratisch, als kubisch geschrieben);
      // Abschnitte mit gleicher Breite (auf 0,05 Ausgabepunkte) bilden einen Pfad
      let width = null;
      for (let i = 1; i < n; i++) {
        const ia = 3 * (i - 1), ib = 3 * i;
        const ax = p[ia], ay = p[ia + 1] - fy, bx = p[ib], by = p[ib + 1] - fy;
        const m0x = i === 1 ? ax : (p[ia - 3] + ax) / 2, m0y = i === 1 ? ay : (p[ia - 2] - fy + ay) / 2;
        const last = i === n - 1;
        const m1x = last ? bx : (ax + bx) / 2, m1y = last ? by : (ay + by) / 2;
        const wv = Math.round(Math.max((p[ia + 2] + p[ib + 2]) / 2, minW) * s * 20) / 20;
        if (wv !== width) {
          if (width !== null) c += "S\n";
          c += `${dec((wv / s) * 10, 2)} w ${N(m0x)} ${N(m0y)} m\n`;
          width = wv;
        }
        // Weicht die Kurve um weniger als die halbe Rundung (0,05 Seitenpunkte) von der Geraden ab: eine Gerade
        const ex = ax - (m0x + m1x) / 2, ey = ay - (m0y + m1y) / 2;
        if (ex * ex + ey * ey < 0.01) c += `${N(m1x)} ${N(m1y)} l\n`;
        else {
          c += `${N(m0x + (2 / 3) * (ax - m0x))} ${N(m0y + (2 / 3) * (ay - m0y))} ` +
            `${N(m1x + (2 / 3) * (ax - m1x))} ${N(m1y + (2 / 3) * (ay - m1y))} ${N(m1x)} ${N(m1y)} c\n`;
        }
      }
      c += "S\n";
    }
    if (wrap) c += "Q\n";
  }
  c += "Q\n";
  const content = zlib.deflateSync(Buffer.from(c, "latin1"), { level: 6 });
  // Objekte: 1 Katalog, 2 Seitenbaum, 3 Schrift, 4 Inhalt, 5 Seite, 6 Bild
  const gs = states.size
    ? ` /ExtGState <<${[...states].map(([key, name]) => {
      const [a, m] = key.split("|");
      return ` /${name} << /Type /ExtGState /CA ${a} /ca ${a}${m === "1" ? " /BM /Multiply" : ""} >>`;
    }).join("")} >>`
    : "";
  const objs = [
    Buffer.from("<< /Type /Catalog /Pages 2 0 R >>"),
    Buffer.from("<< /Type /Pages /Kids [5 0 R] /Count 1 >>"),
    Buffer.from("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>"),
    Buffer.concat([Buffer.from(`<< /Length ${content.length} /Filter /FlateDecode >>\nstream\n`), content, Buffer.from("\nendstream")]),
    Buffer.from(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${PW} ${H}] /Contents 4 0 R /Resources << /Font << /F1 3 0 R >>` +
      `${image ? " /XObject << /Im1 6 0 R >>" : ""}${gs} >> >>`),
  ];
  if (image) {
    objs.push(Buffer.concat([
      Buffer.from(`<< /Type /XObject /Subtype /Image /Width ${image.w} /Height ${image.h} /ColorSpace ` +
        `/${image.comps === 1 ? "DeviceGray" : "DeviceRGB"} /BitsPerComponent 8 /Filter /DCTDecode /Length ${jpeg.length} >>\nstream\n`),
      jpeg, Buffer.from("\nendstream"),
    ]));
  }
  const parts = [Buffer.from("%PDF-1.4\n%\xe2\xe3\xcf\xd3\n", "latin1")];
  let offset = parts[0].length;
  const offsets = [];
  objs.forEach((body, i) => {
    offsets.push(offset);
    const head = Buffer.from(`${i + 1} 0 obj\n`), tail = Buffer.from("\nendobj\n");
    parts.push(head, body, tail);
    offset += head.length + body.length + tail.length;
  });
  parts.push(Buffer.from(`xref\n0 ${objs.length + 1}\n0000000000 65535 f \n` +
    offsets.map((o) => `${String(o).padStart(10, "0")} 00000 n \n`).join("") +
    `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${offset}\n%%EOF\n`));
  return Buffer.concat(parts);
}

// ---------- PDF-Hintergrund (macOS) ----------

// Skript für osascript (JavaScript for Automation, PDFKit und AppKit), liegt als HOME/hintergrund.js. Bekommt nur Pfade
// und ganze Zahlen. hoehen <pdf>: {pages: [{w, h, rot}], heights: [Höhe jeder Seite bei 768 Breite]} aus der CropBox,
// bei 90/270 Grad Drehung Breite und Höhe getauscht. bilder <pdf> <ordner> i:B:H …: Seite i (ab 0) als JPEG mit genau
// B × H Pixeln in <ordner>/bg-<i>.jpg (CropBox, Drehung, ohne Anmerkungen, weißer Grund, Qualität 0,6); gibt
// {ok: [i…], fail: [i…]} aus. Gezeichnet in eine Bitmap genau dieser Größe, so kann der Retina-Faktor nichts ändern.
// farben <ordner> i:x:y …: Farbe des Pixels x, y (oben links 0, 0) in <ordner>/bg-<i>.jpg als {c: [[r, g, b] (0…255)
// oder null, …]} (für die Prüfung, was bilder gezeichnet hat)
export const BG_SCRIPT = `// BetterNotes hintergrund v1
ObjC.import("Foundation");
ObjC.import("AppKit");
ObjC.import("PDFKit");
function run(argv) {
  const CROP = 1; // kPDFDisplayBoxCropBox
  const JPEG = 3; // NSBitmapImageFileTypeJPEG
  if (argv[0] === "farben") {
    const reps = {}, c = [];
    for (const spec of argv.slice(2)) {
      const m = /^(\\d{1,5}):(\\d{1,5}):(\\d{1,5})$/.exec(spec);
      let v = null;
      try {
        if (m) {
          if (!(m[1] in reps)) reps[m[1]] = $.NSBitmapImageRep.imageRepWithData($.NSData.dataWithContentsOfFile(argv[1] + "/bg-" + m[1] + ".jpg"));
          const rep = reps[m[1]];
          let col = rep && !rep.isNil() ? rep.colorAtXY(Number(m[2]), Number(m[3])) : null;
          if (col && !col.isNil()) {
            const rgb = col.colorUsingColorSpace($.NSColorSpace.sRGBColorSpace);
            if (rgb && !rgb.isNil()) col = rgb;
            v = [col.redComponent, col.greenComponent, col.blueComponent].map((x) => Math.round(Number(x) * 255));
          }
        }
      } catch (e) {
        v = null;
      }
      c.push(v);
    }
    return JSON.stringify({ c: c });
  }
  const doc = $.PDFDocument.alloc.initWithURL($.NSURL.fileURLWithPath(argv[1]));
  if (!doc || doc.isNil()) return JSON.stringify({ error: "PDF lässt sich nicht öffnen" });
  const n = doc.pageCount;
  const natural = (page) => {
    const box = page.boundsForBox(CROP);
    const rot = ((Number(page.rotation) % 360) + 360) % 360;
    const turned = rot === 90 || rot === 270;
    const w = box.size.width, h = box.size.height;
    return { w: w, h: h, rot: rot, W: turned ? h : w, H: turned ? w : h };
  };
  if (argv[0] === "hoehen") {
    const pages = [], heights = [];
    for (let i = 0; i < n; i++) {
      const p = natural(doc.pageAtIndex(i));
      pages.push({ w: p.w, h: p.h, rot: p.rot });
      heights.push(p.W > 0 ? 768 * p.H / p.W : 768 * 297 / 210);
    }
    return JSON.stringify({ pages: pages, heights: heights });
  }
  if (argv[0] !== "bilder") return JSON.stringify({ error: "unbekannt" });
  const ok = [], fail = [];
  for (const spec of argv.slice(3)) {
    const m = /^(\\d{1,5}):(\\d{1,5}):(\\d{1,5})$/.exec(spec);
    if (!m) continue;
    const i = Number(m[1]), pw = Number(m[2]), ph = Number(m[3]);
    try {
      if (i >= n || pw < 1 || ph < 1 || pw > 8000 || ph > 8000) throw new Error("Seite fehlt");
      const page = doc.pageAtIndex(i);
      const p = natural(page);
      if (!(p.W > 0 && p.H > 0)) throw new Error("leere Seite");
      const rep = $.NSBitmapImageRep.alloc.initWithBitmapDataPlanesPixelsWidePixelsHighBitsPerSampleSamplesPerPixelHasAlphaIsPlanarColorSpaceNameBytesPerRowBitsPerPixel(
        null, pw, ph, 8, 4, true, false, "NSDeviceRGBColorSpace", 0, 0);
      if (!rep || rep.isNil()) throw new Error("keine Bitmap");
      rep.setSize($.NSMakeSize(pw, ph));
      const ctx = $.NSGraphicsContext.graphicsContextWithBitmapImageRep(rep);
      if (!ctx || ctx.isNil()) throw new Error("kein Grafikkontext");
      $.NSGraphicsContext.saveGraphicsState;
      $.NSGraphicsContext.setCurrentContext(ctx);
      try {
        $.NSColor.whiteColor.setFill;
        $.NSBezierPath.fillRect($.NSMakeRect(0, 0, pw, ph));
        // Die gedrehte CropBox liegt nach drawWithBox bei (0, 0) in ihrer gedrehten Größe: auf B × H strecken
        const t = $.NSAffineTransform.transform;
        t.scaleXByYBy(pw / p.W, ph / p.H);
        t.concat;
        page.setDisplaysAnnotations(false);
        page.drawWithBoxToContext(CROP, ctx.CGContext);
        ctx.flushGraphics;
      } finally {
        $.NSGraphicsContext.restoreGraphicsState;
      }
      const props = $.NSDictionary.dictionaryWithObjectForKey($.NSNumber.numberWithDouble(0.6), "NSImageCompressionFactor");
      const data = rep.representationUsingTypeProperties(JPEG, props);
      if (!data || data.isNil() || !data.writeToFileAtomically(argv[2] + "/bg-" + i + ".jpg", true)) throw new Error("nicht geschrieben");
      ok.push(i);
    } catch (e) {
      fail.push(i);
    }
  }
  return JSON.stringify({ ok: ok, fail: fail });
}
`;

/// Kleines PDF zum Prüfen von BG_SCRIPT: Hochformat, Querformat, gedreht (/Rotate 90) und eines mit eigener CropBox
/// (weit weg von der MediaBox), auf jeder Seite ein blaues und ein rotes Rechteck. heights: was hoehen liefern muss;
/// marks: je Seite, welche Farbe wo im Bild sein muss (Anteile fx, fy ab oben links; die Mitten der Rechtecke, soweit
/// sie in der CropBox liegen, und Weiß in deren Mitte), wie die App die Seite zeichnet (getDrawingTransform, CropBox)
export function probePDF() {
  const pages = [
    { media: [0, 0, 200, 283] },
    { media: [0, 0, 283, 200] },
    { media: [0, 0, 200, 283], rotate: 90 },
    { media: [0, 0, 200, 283], crop: [30, 100, 200, 283] },
  ];
  const objs = ["<< /Type /Catalog /Pages 2 0 R >>", null];
  const kids = [];
  for (const p of pages) {
    const stream = `0 0 0.6 rg 10 10 60 40 re f 0.8 0 0 rg 120 150 50 30 re f\n`;
    objs.push(`<< /Length ${stream.length} >>\nstream\n${stream}endstream`);
    objs.push(`<< /Type /Page /Parent 2 0 R /MediaBox [${p.media.join(" ")}]${p.crop ? ` /CropBox [${p.crop.join(" ")}]` : ""}` +
      `${p.rotate ? ` /Rotate ${p.rotate}` : ""} /Contents ${objs.length} 0 R /Resources << >> >>`);
    kids.push(objs.length);
  }
  objs[1] = `<< /Type /Pages /Kids [${kids.map((k) => `${k} 0 R`).join(" ")}] /Count ${kids.length} >>`;
  let out = "%PDF-1.4\n";
  const offsets = [];
  objs.forEach((o, i) => {
    offsets.push(out.length);
    out += `${i + 1} 0 obj\n${o}\nendobj\n`;
  });
  const xref = out.length;
  out += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n` + offsets.map((o) => `${String(o).padStart(10, "0")} 00000 n \n`).join("") +
    `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  const heights = pages.map((p) => {
    const [x0, y0, x1, y1] = p.crop || p.media;
    const turned = p.rotate === 90 || p.rotate === 270;
    const w = turned ? y1 - y0 : x1 - x0, h = turned ? x1 - x0 : y1 - y0;
    return (LAYOUT.W * h) / w;
  });
  const marks = pages.map((p) => {
    const [x0, y0, x1, y1] = p.crop || p.media;
    const spots = [{ color: "blau", x: 40, y: 30 }, { color: "rot", x: 145, y: 165 }].filter((m) => m.x > x0 && m.x < x1 && m.y > y0 && m.y < y1);
    return [...spots, { color: "weiß", x: (x0 + x1) / 2, y: (y0 + y1) / 2 }].map(({ color, x, y }) => {
      const u = (x - x0) / (x1 - x0), v = (y - y0) / (y1 - y0);
      // Um 90 Grad im Uhrzeigersinn gedreht: links unten wird links oben
      return p.rotate === 90 ? { color, fx: v, fy: u } : { color, fx: u, fy: 1 - v };
    });
  });
  return { pdf: Buffer.from(out, "latin1"), heights, marks };
}

// ---------- Dateien ----------

function writeAtomic(file, data) {
  const tmp = `${file}.${process.pid}.tmp`;
  try {
    fs.writeFileSync(tmp, data);
    fs.renameSync(tmp, file);
  } catch (e) {
    // Platte voll oder Ähnliches: keine halbe Kopie liegen lassen (der Fehler geht so weiter, wie er war)
    try {
      fs.rmSync(tmp, { force: true });
    } catch {}
    throw e;
  }
}

/// Zwischendateien von writeAtomic, die ein hart beendeter Helfer (Strom weg) liegen ließ: nur genau diese Namen, älter
/// als ein Tag
function dropStaleTmp(dir, names, t) {
  for (const name of listDir(dir)) {
    const m = /^(.+)\.\d+\.tmp$/.exec(name);
    if (!m || !names.includes(m[1])) continue;
    try {
      const p = path.join(dir, name), st = fs.statSync(p);
      if (st.isFile() && t - st.mtimeMs > DAY) fs.rmSync(p, { force: true });
    } catch {}
  }
}

function readJSON(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (e) {
    if (LOCAL_ERRORS.has(e.code)) throw e;
    return null;
  }
}

function listDir(dir) {
  try {
    return fs.readdirSync(dir).filter((n) => !n.startsWith("."));
  } catch {
    return [];
  }
}

function exists(file) {
  try {
    return fs.statSync(file).isFile();
  } catch {
    return false;
  }
}

const tick = () => new Promise((r) => setImmediate(r));
/// Wartet ms, endet aber gleich, wenn `signal` abbricht
const sleep = (ms, signal) => new Promise((resolve) => {
  if (signal?.aborted) return resolve();
  const done = () => {
    clearTimeout(t);
    signal?.removeEventListener("abort", done);
    resolve();
  };
  const t = setTimeout(done, ms);
  signal?.addEventListener("abort", done);
});

// ---------- Spiegel, Zeichnen, Übergabe ----------

/// Der Teil mit Zustand. Bekommt von helfer.mjs:
/// - HOME: Ordner des Helfers. Hier liegen spiegel/<Dokument>/ (striche.ndjson, stand.json), seitenbilder/<Dokument>/
///   (gezeichnete Seiten <sha1>.pdf, PDF-Hintergründe v<pdfVersion>/) und hintergrund.js; unter chats/ schreibt das
///   Modul nur die Kopien in fragen/<id>/weitere/
/// - api(method, path, {timeout, signal}) → Promise<{data, type}>: der Server (mit Schlüssel); Fehler mit .status und
///   .body; signal bricht ab (warm())
/// - log(...teile): Protokoll
/// - runOsascript(args, {timeout, signal}) → Promise<stdout>: osascript mit sauberer Umgebung (cleanEnv); scheitert mit
///   Error(stderr), signal beendet es. Hier immer ["-l", "JavaScript", HOME/hintergrund.js, Art, …], nur Pfade und Zahlen
/// - getConfig() → die aktuellen Einstellungen (morePages, mirrorRowsPerDay; fehlende wie DEFAULTS_WEITERE)
/// - state, saveState(state): der gespeicherte Zustand des Helfers; dieses Modul nutzt nur state.weitere (Zeilen am
///   Tag) und liest state.docs[<Dokument>].pdfVersion (Stand von dokument.pdf im Chat-Ordner)
/// - now() → ms (Tests geben eine eigene Uhr)
/// - warmBatchMs: höchstens so lange je Stapel PDF-Hintergründe in warm() (nur Tests geben weniger als 20 s)
/// Gibt { prepare, warm, prune } zurück
export function create({ HOME, api, log = () => {}, runOsascript, getConfig = () => ({}), state, saveState = () => {}, now = Date.now, warmBatchMs = 20000 }) {
  const SPIEGEL = path.join(HOME, "spiegel"), BILDER = path.join(HOME, "seitenbilder");
  const SCRIPT = path.join(HOME, "hintergrund.js");
  const mirrors = new Map(); // Dokument → Spiegel im Speicher (die zwei zuletzt benutzten)
  const pending = new Map(); // Dokument → was warm() noch fertig machen kann (die zwei letzten)
  const gone = new Set(); // am Server gelöscht: warm() holt ihre Kopie nicht mehr vorab (eine Frage dazu schon)
  // PDF-Seiten, an denen osascript so lange hing, wie ein ganzer Stapel in warm() darf, ohne einen Hintergrund fertig
  // zu bekommen: „Dokument:PDF-Stand:Seite“ → {until}. So lange bleibt ihr Hintergrund aus (sonst wartete jede Frage
  // dazu darauf): beim ersten Mal eine Stunde (vielleicht war nur der Mac gerade langsam, oder osascript hing schon vor
  // der Seite), hängt sie binnen einer Woche danach wieder, einen Tag
  const slow = new Map();
  const warned = new Set();
  let probe = null; // Prüfung von hintergrund.js: null noch nicht, sonst true/false
  let probeLater = false; // eine Frage kam mit der Prüfung bis zu ihrer Frist nicht durch: warm() prüft in Ruhe
  let lastCall = -Infinity; // Ende des letzten Abrufs (now())
  // Server ohne die Route bis dahin; nur im Speicher: Nach dem Server-Update und einem Neustart gleich wieder fragen
  let noRouteUntil = 0;
  // warm() scheiterte am Mac selbst (etwa die Platte voll): bis dahin nichts in Ruhe. Konnte eine Frage ihre Kopie der
  // Striche inzwischen schreiben, gibt liftLocal() warm() gleich wieder frei, aber höchstens einmal je Stunde (trifft der
  // Fehler nur warm(), läse es sonst nach jeder Frage dieselben Zeilen am Server, nur um sie wegzuwerfen)
  let localUntil = 0, localLifted = -Infinity;
  const liftLocal = () => {
    if (now() < localUntil && now() - localLifted >= HOUR) {
      localUntil = 0;
      localLifted = now();
    }
  };
  let warming = null; // solange warm() läuft: {signal}, bricht den laufenden Abruf bzw. osascript ab
  let chain = Promise.resolve();

  const once = (key, ...parts) => {
    if (warned.has(key)) return;
    warned.add(key);
    log(...parts);
  };
  // Immer nur eines auf einmal (prepare, warm, prune teilen sich Spiegel und Dateien)
  const exclusive = (fn) => {
    const run = chain.then(fn, fn);
    chain = run.catch(() => {});
    return run;
  };

  function config() {
    const c = getConfig() || {};
    const pick = (v, d) => (isNum(v) && v >= 0 ? v : d);
    const D = DEFAULTS_WEITERE;
    return {
      morePages: { quick: pick(c.morePages?.quick, D.morePages.quick), thorough: pick(c.morePages?.thorough, D.morePages.thorough) },
      mirrorRowsPerDay: pick(c.mirrorRowsPerDay, D.mirrorRowsPerDay),
    };
  }

  /// state.weitere: {day, rows} gelesene Zeilen heute (UTC)
  function counter() {
    if (!state.weitere || typeof state.weitere !== "object") state.weitere = {};
    const w = state.weitere;
    const day = new Date(now()).toISOString().slice(0, 10);
    if (w.day !== day) {
      w.day = day;
      w.rows = 0;
    }
    if (!isNum(w.rows)) w.rows = 0;
    return w;
  }

  // ---------- Spiegel ----------

  function emptyMirror(doc) {
    return {
      doc, dir: path.join(SPIEGEL, doc), file: path.join(SPIEGEL, doc, "striche.ndjson"),
      byId: new Map(), lines: 0, bytes: 0, cursor: 0, top: 0, meta: null, complete: false, used: 0, sorted: null,
    };
  }

  function remember(m, seq, id, st) {
    if (st && Array.isArray(st.p) && st.p.length >= 3 && Array.isArray(st.b) && st.b.length === 4) {
      st.id = id;
      st.seq = seq;
      m.byId.set(id, st);
    } else {
      m.byId.delete(id);
    }
    m.sorted = null;
  }

  /// Spiegel eines Dokuments, von der Platte, wenn nötig. Eine halb geschriebene letzte Zeile (Absturz beim Anhängen)
  /// fällt weg: stand.json wird erst danach geschrieben, der nächste Abruf holt sie neu. Ist die Datei kürzer oder hat
  /// sie weniger Zeilen, als stand.json sagt (Strom weg, bevor das Angehängte auf der Platte war), von vorn
  function mirror(doc) {
    let m = mirrors.get(doc);
    if (m) {
      mirrors.delete(doc);
      mirrors.set(doc, m);
      return m;
    }
    m = emptyMirror(doc);
    const stand = readJSON(path.join(m.dir, "stand.json"));
    let buf = null;
    if (stand && Number.isInteger(stand.cursor) && stand.cursor > 0) {
      try {
        buf = fs.readFileSync(m.file);
      } catch (e) {
        if (LOCAL_ERRORS.has(e.code)) throw e;
      }
    }
    if (buf !== null) {
      const end = buf.lastIndexOf(0x0a) + 1;
      if (end < buf.length) fs.truncateSync(m.file, end);
      for (const line of buf.subarray(0, end).toString("utf8").split("\n")) {
        if (!line) continue;
        let r;
        try {
          r = JSON.parse(line);
        } catch {
          continue;
        }
        if (!Array.isArray(r) || typeof r[1] !== "string" || !Number.isInteger(r[0])) continue;
        remember(m, r[0], r[1], r[2]);
        m.lines++;
      }
      m.bytes = end;
      if ((Number.isInteger(stand.bytes) && end < stand.bytes) || (Number.isInteger(stand.lines) && m.lines < stand.lines)) {
        log(`Weitere Seiten: Spiegel ${doc.slice(0, 8)} auf der Platte unvollständig, von vorn`);
        m = emptyMirror(doc);
        buf = null;
      }
    }
    if (buf === null) {
      // Nichts oder nichts Stimmiges da: von vorn
      fs.rmSync(m.dir, { recursive: true, force: true });
    } else {
      m.cursor = stand.cursor;
      m.top = Number.isInteger(stand.top) ? stand.top : 0;
      m.meta = stand.meta && typeof stand.meta === "object" ? stand.meta : null;
      m.complete = Boolean(stand.complete);
      m.used = isNum(stand.used) ? stand.used : 0;
    }
    mirrors.set(doc, m);
    while (mirrors.size > 2) mirrors.delete(mirrors.keys().next().value);
    return m;
  }

  function writeStand(m) {
    fs.mkdirSync(m.dir, { recursive: true });
    writeAtomic(path.join(m.dir, "stand.json"), JSON.stringify({
      cursor: m.cursor, top: m.top, complete: m.complete, used: m.used, meta: m.meta, bytes: m.bytes, lines: m.lines,
    }));
  }

  /// Von vorn (die Striche am Server wurden gelöscht und neu angelegt)
  function resetMirror(m) {
    fs.rmSync(m.dir, { recursive: true, force: true });
    Object.assign(m, { byId: new Map(), lines: 0, bytes: 0, cursor: 0, top: 0, meta: null, complete: false, sorted: null });
  }

  /// Dokument gelöscht: Spiegel und gezeichnete Seiten weg
  function dropDoc(doc) {
    mirrors.delete(doc);
    pending.delete(doc);
    fs.rmSync(path.join(SPIEGEL, doc), { recursive: true, force: true });
    fs.rmSync(path.join(BILDER, doc), { recursive: true, force: true });
  }

  /// Neue Zeilen anhängen; sind mehr Zeilen tot (ersetzt, gelöscht) als lebendig, die Datei neu schreiben
  function applyChanges(m, changes) {
    let text = "";
    for (const ch of changes) {
      if (!ch || typeof ch.id !== "string" || !ch.id || ch.id.length > 200 || !Number.isInteger(ch.seq)) continue;
      const st = typeof ch.data === "string" ? compactStroke(ch.data) : null;
      text += JSON.stringify([ch.seq, ch.id, st]) + "\n";
      remember(m, ch.seq, ch.id, st);
      m.lines++;
    }
    fs.mkdirSync(m.dir, { recursive: true });
    if (text) {
      fs.appendFileSync(m.file, text);
      m.bytes += Buffer.byteLength(text);
    }
    if (m.lines - m.byId.size > m.byId.size) {
      const live = sorted(m);
      const all = live.map((st) => JSON.stringify([st.seq, st.id, { k: st.k, c: st.c, p: st.p, b: st.b, s: st.s }]) + "\n").join("");
      writeAtomic(m.file, all);
      m.lines = live.length;
      m.bytes = Buffer.byteLength(all);
    }
  }

  /// Die lebenden Striche in seq-Reihenfolge
  function sorted(m) {
    if (!m.sorted) m.sorted = [...m.byId.values()].sort((a, b) => a.seq - b.seq);
    return m.sorted;
  }

  /// Holt, was seit dem letzten Stand dazukam: GET /api/doc/<id>/strokes, je 500, nacheinander mit Pause, bis nichts
  /// mehr kommt, die Frist um ist oder die Zeilen des Tages aufgebraucht sind. `check(meta)` kann nach jedem Abruf mit
  /// einem Grund abbrechen. Gibt {} (fertig) oder {off: Grund} zurück
  async function pull(m, { deadline, isCancelled, check }) {
    let calls = 0, rows = 0;
    try {
      for (;;) {
        if (isCancelled()) return { off: "abgebrochen" };
        if (now() < noRouteUntil) return { off: "Server ohne Route" };
        const w = counter();
        // Der erste Abruf auch nach der Frist: Ist der Spiegel schon fertig, genügt er (die gezeichneten Seiten sind da)
        if (calls && now() >= deadline) return { off: "Spiegel nicht fertig" };
        const cap = config().mirrorRowsPerDay;
        const limit = Math.min(PULL_LIMIT, Math.floor(cap - w.rows - 4));
        if (limit < 1) {
          once(`cap:${w.day}`, `Weitere Seiten: ${cap} gelesene Zeilen am Server heute erreicht, der Spiegel holt morgen weiter`);
          return { off: "Tageslimit erreicht" };
        }
        // Die Pause bricht warm() mit ab (ein Lernwort wartet sonst bis zu ihrem Ende)
        const signal = warming?.signal;
        const wait = lastCall + PULL_GAP_MS - now();
        if (wait > 0) await sleep(Math.min(wait, PULL_GAP_MS), signal);
        if (isCancelled()) return { off: "abgebrochen" };
        let res;
        try {
          const timeout = Math.round(Math.min(30000, Math.max(3000, deadline - now())));
          res = (await api("GET", `/api/doc/${m.doc}/strokes?since=${m.cursor}&limit=${limit}&lite=1`, { timeout, ...(signal ? { signal } : {}) })).data;
        } catch (e) {
          if (LOCAL_ERRORS.has(e.code)) throw e;
          if (signal?.aborted) return { off: "abgebrochen" };
          if (e.status === 404 && !(e.body && typeof e.body === "object" && e.body.code)) {
            noRouteUntil = now() + NO_ROUTE_MS;
            once("noroute", "Weitere Seiten: Der Server kennt die Striche-Abfrage noch nicht (Server-Update nötig), neuer Versuch alle 10 Minuten");
            return { off: "Server ohne Route" };
          }
          return { off: e.status ? `Server-Fehler (HTTP ${e.status})` : "Server nicht erreichbar" };
        } finally {
          lastCall = now();
        }
        calls++;
        noRouteUntil = 0;
        const changes = Array.isArray(res?.changes) ? res.changes : null;
        // Gelesen hat der Server die Zeilen der Antwort und vier weitere (höchste und niedrigste Nummer, Metadaten, die
        // erste, die nicht mehr mitkam); endet das Stück an der Zeichengrenze statt an limit, eine mehr (er liest eine
        // Zeile voraus)
        const read = (changes?.length || 0) + (res?.more === true && changes && changes.length < limit ? 5 : 4);
        rows += read;
        w.rows += read;
        if (!changes || !Number.isInteger(res.top) || !Number.isInteger(res.last) || typeof res.more !== "boolean") {
          return { off: signal?.aborted ? "abgebrochen" : "Antwort des Servers unbrauchbar" };
        }
        if (res.meta?.deleted) {
          dropDoc(m.doc);
          log(`Weitere Seiten: Dokument ${m.doc.slice(0, 8)} am Server gelöscht, Spiegel und Seiten entfernt`);
          return { off: "Dokument gelöscht" };
        }
        // Seit dem Stand am Server gelöscht und wieder angelegt oder zurückgeholt: Nur dabei verschwinden Zeilen, und die
        // Nummern zählen über alle Dokumente. Darum heißt eine niedrigste Nummer über dem Stand (oder eine höchste
        // darunter), dass der Spiegel Striche haben kann, die es nicht mehr gibt: von vorn
        const wiped = Number.isInteger(res.low) && res.low > m.cursor;
        if (m.cursor > 0 && (res.top < m.cursor || wiped)) {
          log(`Weitere Seiten: Striche von ${m.doc.slice(0, 8)} am Server neu, Spiegel von vorn`);
          resetMirror(m);
          // Sind alle Zeilen neuer als der alte Stand, ist diese Antwort dieselbe wie ab 0
          if (!wiped) continue;
        }
        if (res.last < m.cursor || (res.more && !changes.length)) return { off: "Antwort des Servers unbrauchbar" };
        applyChanges(m, changes);
        m.cursor = res.last;
        m.top = res.top;
        m.meta = res.meta && typeof res.meta === "object" ? res.meta : null;
        m.complete = !res.more;
        writeStand(m);
        const why = check?.(m.meta);
        if (why) return { off: why };
        if (!res.more) return {};
      }
    } finally {
      if (calls) saveState(state);
      if (calls > 2) log(`Weitere Seiten: Spiegel ${m.doc.slice(0, 8)}: ${calls} Abrufe, ${rows} Zeilen, ${m.byId.size} Striche${m.complete ? "" : ", noch nicht fertig"}`);
    }
  }

  // ---------- PDF-Hintergrund ----------

  /// hintergrund.js wie BG_SCRIPT (neu geschrieben: noch einmal prüfen)
  function ensureScript() {
    let cur = null;
    try {
      cur = fs.readFileSync(SCRIPT, "utf8");
    } catch {}
    if (cur === BG_SCRIPT) return;
    fs.mkdirSync(HOME, { recursive: true });
    writeAtomic(SCRIPT, BG_SCRIPT);
    probe = null;
  }

  /// osascript mit hintergrund.js, höchstens `timeout` ms. Scheitert es erst nach (fast) der ganzen Zeit, ist die Zeit um
  /// (Fehler mit .timedOut); hat warm() abgebrochen, Fehler mit .aborted (beides kein Fehler des Skripts)
  async function osa(args, timeout) {
    ensureScript();
    const signal = warming?.signal;
    if (signal?.aborted) throw Object.assign(new Error("abgebrochen"), { aborted: true });
    const t0 = Date.now();
    try {
      return String(await runOsascript(["-l", "JavaScript", SCRIPT, ...args], { timeout: Math.round(timeout), ...(signal ? { signal } : {}) })).trim();
    } catch (e) {
      if (e && typeof e === "object") {
        if (signal?.aborted) e.aborted = true;
        else if (Date.now() - t0 >= timeout - 50) e.timedOut = true;
      }
      throw e;
    }
  }

  /// Geht hintergrund.js hier? Einmal je Start (und nach einer Änderung des Skripts) an einem kleinen PDF: Höhen samt
  /// Querformat, Drehung und CropBox, Bilder genau in der verlangten Größe und darauf die Farben, wo sie hingehören.
  /// Sonst bei PDFs keine weiteren Seiten. Jeder Schritt höchstens 30 s, für eine Frage höchstens bis zu ihrer Frist:
  /// Ist nur diese kürzere Zeit um (oder hat warm() abgebrochen), gilt die Prüfung als nicht gemacht (null; warm()
  /// prüft in Ruhe noch einmal), statt PDFs bis zum Neustart abzuschalten
  async function probeOK(deadline = Infinity) {
    ensureScript();
    if (probe !== null) return probe;
    const dir = path.join(BILDER, "_probe");
    let why = null, short = false;
    const limit = () => {
      const ms = Math.min(30000, Math.max(1000, deadline - now()));
      short = ms < 30000;
      return ms;
    };
    try {
      fs.rmSync(dir, { recursive: true, force: true });
      fs.mkdirSync(dir, { recursive: true });
      const { pdf, heights, marks } = probePDF();
      const file = path.join(dir, "probe.pdf");
      fs.writeFileSync(file, pdf);
      const h = JSON.parse(await osa(["hoehen", file], limit()));
      if (!Array.isArray(h?.heights) || h.heights.length !== heights.length ||
        h.heights.some((v, i) => !(Math.abs(v - heights[i]) < 0.5))) {
        why = `Höhen falsch (${JSON.stringify(h?.heights || h).slice(0, 120)})`;
      } else {
        const want = heights.map((v, i) => [i, 96, Math.round(v / 8)]);
        const b = JSON.parse(await osa(["bilder", file, dir, ...want.map((x) => x.join(":"))], limit()));
        for (const [i, pw, ph] of want) {
          let info = null;
          try {
            info = jpegInfo(fs.readFileSync(path.join(dir, `bg-${i}.jpg`)));
          } catch {}
          if (!b?.ok?.includes(i) || !info || info.w !== pw || info.h !== ph) {
            why = `Bild ${i + 1} ${info ? `${info.w} × ${info.h} statt ${pw} × ${ph}` : "fehlt"}`;
            break;
          }
        }
        if (!why) {
          // Richtig gezeichnet (gedreht, die CropBox, überhaupt etwas)? JPEG verschiebt Farben etwas: großzügig
          const spots = want.flatMap(([i, pw, ph]) => marks[i].map((m) => ({
            i, color: m.color, x: Math.min(pw - 1, Math.floor(m.fx * pw)), y: Math.min(ph - 1, Math.floor(m.fy * ph)),
          })));
          const got = JSON.parse(await osa(["farben", dir, ...spots.map((m) => `${m.i}:${m.x}:${m.y}`)], limit()))?.c;
          const looks = (color, c) => {
            if (!Array.isArray(c) || c.length !== 3 || !c.every(isNum)) return false;
            const [r, g, b] = c;
            if (color === "blau") return b > 100 && b - Math.max(r, g) > 60;
            if (color === "rot") return r > 120 && r - Math.max(g, b) > 60;
            return Math.min(r, g, b) > 200;
          };
          const bad = spots.findIndex((m, k) => !looks(m.color, Array.isArray(got) ? got[k] : null));
          if (bad >= 0) {
            const m = spots[bad], c = Array.isArray(got) ? got[bad] : null;
            why = `Bild ${m.i + 1} falsch gezeichnet (${m.color} bei ${m.x}, ${m.y}: ${Array.isArray(c) ? c.join(", ") : "keine Farbe"})`;
          }
        }
      }
    } catch (e) {
      if (LOCAL_ERRORS.has(e.code)) throw e;
      if (e.aborted) {
        probeLater = true;
        return null;
      }
      if (e.timedOut && short) {
        probeLater = true;
        once("probe-frist", "Weitere Seiten: PDF-Hintergrund bis zur Frist der Frage nicht geprüft, neuer Versuch in Ruhe");
        return null;
      }
      why = (e.message || "keine Ausgabe").split("\n")[0].slice(0, 200);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
    probe = !why;
    log(probe ? "Weitere Seiten: PDF-Hintergrund geprüft" : `Weitere Seiten: PDF-Hintergrund geht nicht (${why}), bei PDFs ohne weitere Seiten`);
    return probe;
  }

  /// Seitenhöhen des PDFs (bei 768 Breite), je PDF-Stand einmal (seitenbilder/<Dokument>/v<pdfVersion>/hoehen.json;
  /// ältere Stände weg). osascript höchstens 60 s, für eine Frage höchstens bis zu ihrer Frist. null, wenn es nicht geht
  async function heightsFor(doc, version, pdfPath, deadline = Infinity) {
    const base = path.join(BILDER, doc), vdir = path.join(base, `v${version}`), file = path.join(vdir, "hoehen.json");
    const valid = (h) => Array.isArray(h) && h.length >= 1 && h.length <= MAX_PAGES && h.every((v) => isNum(v) && v > 0 && v < 1e6);
    const cached = readJSON(file);
    if (valid(cached?.heights)) {
      touch(file);
      return cached.heights;
    }
    for (const name of listDir(base)) if (/^v\d+$/.test(name) && name !== `v${version}`) fs.rmSync(path.join(base, name), { recursive: true, force: true });
    let out;
    try {
      out = JSON.parse(await osa(["hoehen", pdfPath], Math.min(60000, Math.max(1000, deadline - now()))));
    } catch (e) {
      if (LOCAL_ERRORS.has(e.code)) throw e;
      if (e.aborted) return null;
      once(`hoehen:${doc}:${version}`, `Weitere Seiten: Seitenhöhen von ${doc.slice(0, 8)} nicht gelesen:`,
        e.timedOut ? "Zeit um" : (e.message || "").split("\n")[0].slice(0, 200));
      return null;
    }
    if (!valid(out?.heights)) {
      once(`hoehen:${doc}:${version}`, `Weitere Seiten: Seitenhöhen von ${doc.slice(0, 8)} unbrauchbar`);
      return null;
    }
    fs.mkdirSync(vdir, { recursive: true });
    writeAtomic(file, JSON.stringify({ pages: Array.isArray(out.pages) ? out.pages : [], heights: out.heights }));
    return out.heights;
  }

  /// Hintergrund der Seite i, wenn er da ist und genau so groß wie verlangt
  function readBackground(ctx, i) {
    const file = path.join(BILDER, ctx.doc, `v${ctx.pdfVersion}`, `bg-${i}.jpg`);
    let buf;
    try {
      buf = fs.readFileSync(file);
    } catch (e) {
      if (LOCAL_ERRORS.has(e.code)) throw e;
      return null;
    }
    const { PW, PH } = pageGeometry(ctx.frames[i].h);
    const info = jpegInfo(buf);
    if (!info || info.w !== PW || info.h !== PH) {
      fs.rmSync(file, { force: true });
      once(`bgsize:${ctx.doc}`, `Weitere Seiten: Hintergrund von Seite ${i + 1} hat die falsche Größe, verworfen`);
      return null;
    }
    touch(file);
    return buf;
  }

  /// Fehlende Hintergründe der Seiten `pages` in einem Aufruf von osascript (höchstens bis zur Frist, 120 s; in warm()
  /// 20 s: Hängt eine Seite, sind die übrigen trotzdem dran). Gibt {made, timedOut, stalled} zurück: made so viele
  /// Hintergründe neu (auch wenn die Zeit um war: hintergrund.js schreibt jede gleich), timedOut die Zeit war um,
  /// stalled und zwar so lange, wie ein ganzer Stapel in warm() darf, ohne einen neuen. Dann hing es an der ersten Seite
  /// (oder schon davor); die lässt der Helfer eine Weile aus (siehe slow)
  async function drawBackgrounds(ctx, pages, deadline) {
    const res = { made: 0, timedOut: false, stalled: false };
    const slowKey = (i) => `${ctx.doc}:${ctx.pdfVersion}:${i}`;
    const want = pages.filter((i) => now() >= (slow.get(slowKey(i))?.until ?? 0) && !readBackground(ctx, i));
    if (!want.length) return res;
    const vdir = path.join(BILDER, ctx.doc, `v${ctx.pdfVersion}`);
    fs.mkdirSync(vdir, { recursive: true });
    const specs = want.map((i) => {
      const { PW, PH } = pageGeometry(ctx.frames[i].h);
      return `${i}:${PW}:${PH}`;
    });
    const most = warming ? warmBatchMs : 120000, timeout = Math.max(1000, Math.min(most, deadline - now()));
    try {
      const out = JSON.parse(await osa(["bilder", ctx.pdfPath, vdir, ...specs], timeout));
      if (out?.fail?.length) once(`bgfail:${ctx.doc}`, `Weitere Seiten: Hintergrund nicht gezeichnet (${ctx.doc.slice(0, 8)}, Seite ${pageRangesShort(out.fail.map((i) => i + 1))})`);
    } catch (e) {
      if (LOCAL_ERRORS.has(e.code)) throw e;
      // Zeit um oder abgebrochen: kein Fehler des Skripts (die Seiten sind dann nicht bereit); ins Protokoll kommt nur
      // ein ganzer Stapel, der zu lange brauchte, nicht die Frist einer Frage
      if (e.timedOut) {
        res.timedOut = true;
        if (timeout >= most) once(`bgzeit:${ctx.doc}`, `Weitere Seiten: Hintergründe nicht gezeichnet (${ctx.doc.slice(0, 8)}): Zeit um nach ${Math.round(timeout / 1000)} s`);
      } else if (!e.aborted) {
        once(`bgerr:${ctx.doc}`, `Weitere Seiten: Hintergründe nicht gezeichnet (${ctx.doc.slice(0, 8)}):`, (e.message || "keine Ausgabe").split("\n")[0].slice(0, 200));
      }
    }
    res.made = want.filter((i) => exists(path.join(vdir, `bg-${i}.jpg`))).length;
    if (res.timedOut && !res.made && timeout >= warmBatchMs) {
      res.stalled = true;
      // Hing sie schon einmal, und ihre Pause endete vor weniger als einer Woche: diesmal einen Tag
      const key = slowKey(want[0]), before = slow.get(key), long = Boolean(before) && now() - before.until < WEEK;
      slow.set(key, { until: now() + (long ? DAY : HOUR) });
      log(`Weitere Seiten: Hintergrund von Seite ${want[0] + 1} (${ctx.doc.slice(0, 8)}) nach ${Math.round(timeout / 1000)} s nicht fertig, ${long ? "einen Tag" : "eine Stunde"} lang ausgelassen`);
    }
    return res;
  }

  // ---------- Zeichnen ----------

  function touch(file) {
    const t = new Date(now());
    try {
      fs.utimesSync(file, t, t);
    } catch {}
  }

  function cacheKey(ctx, i) {
    const f = ctx.frames[i];
    const list = (ctx.byPage.get(i) || []).map((st) => `${st.id}:${st.seq}`).join(",");
    return sha1(`${RENDER_VERSION}\n${i}\n${f.y.toFixed(2)}\n${f.h.toFixed(2)}\n${ctx.isPDF ? ctx.pdfVersion : "grid"}\n${list}`);
  }

  /// Zeichnet die Seiten `order` (die nächsten zuerst) in seitenbilder/, soweit nicht schon da: zwischen den Seiten
  /// Frist und Abbruch prüfen. Gibt {ready: Map Seite → {file, key}, notReady, drawn, cancelled, made, timedOut,
  /// stalled} zurück (die letzten drei für die PDF-Hintergründe aller Stapel zusammen, wie bei drawBackgrounds)
  async function render(ctx, order, { deadline, isCancelled }) {
    const ready = new Map(), notReady = [];
    let drawn = 0, made = 0, timedOut = false, stalled = false;
    const result = (cancelled) => ({ ready, notReady, drawn, cancelled, made, timedOut, stalled });
    fs.mkdirSync(path.join(BILDER, ctx.doc), { recursive: true });
    for (let k = 0; k < order.length; k += BG_BATCH) {
      const chunk = order.slice(k, k + BG_BATCH).map((i) => {
        const key = cacheKey(ctx, i);
        return { i, key, file: path.join(BILDER, ctx.doc, `${key}.pdf`) };
      });
      const missing = chunk.filter((j) => !exists(j.file)).map((j) => j.i);
      if (ctx.isPDF && missing.length && deadline - now() > 1000 && !isCancelled()) {
        const bg = await drawBackgrounds(ctx, missing, deadline);
        made += bg.made;
        timedOut ||= bg.timedOut;
        stalled ||= bg.stalled;
      }
      for (const j of chunk) {
        if (isCancelled()) return result(true);
        if (exists(j.file)) {
          touch(j.file);
          ready.set(j.i, j);
          continue;
        }
        if (now() >= deadline) {
          notReady.push(j.i);
          continue;
        }
        const jpeg = ctx.isPDF ? readBackground(ctx, j.i) : null;
        if (ctx.isPDF && !jpeg) {
          notReady.push(j.i);
          continue;
        }
        writeAtomic(j.file, pagePDF({ frame: ctx.frames[j.i], strokes: ctx.byPage.get(j.i) || [], label: `Seite ${j.i + 1}`, jpeg }));
        touch(j.file);
        drawn++;
        ready.set(j.i, j);
        await tick();
      }
    }
    return result(false);
  }

  /// Seiten, Striche je Seite und was davon angeboten wird, aus dem Spiegel. info: {q, isPDF, pdfPath, pdfVersion,
  /// spanEnd, span (ab 1), contextFile}; deadline für die Seitenhöhen des PDFs. Gibt {off} zurück, wenn es nicht geht
  async function model(m, info, deadline) {
    const strokes = sorted(m);
    const meta = m.meta || {};
    let frames, byPage;
    if (info.isPDF) {
      const heights = await heightsFor(m.doc, info.pdfVersion, info.pdfPath, deadline);
      if (!heights) return { off: "PDF-Hintergrund geht nicht" };
      frames = pdfFrames(heights);
      byPage = inkByPage(strokes, frames);
    } else {
      const n0 = Math.min(MAX_PAGES, Math.max(Number(meta.pageCount) || 0, info.spanEnd || 0, info.q + 1));
      byPage = inkByPage(strokes, notebookFrames(n0), { grow: true });
      frames = notebookFrames(Math.max(n0, ...[...byPage.keys()].map((i) => i + 1)));
    }
    const written = [...byPage.keys()].sort((a, b) => a - b);
    // Die Seiten um die Frage hat Claude schon von der App, wenn sie angekommen sind (oder dort sonst nichts steht)
    let covered = [];
    if (Array.isArray(info.span)) {
      const [a, b] = info.span;
      const inSpan = written.filter((i) => i + 1 >= a && i + 1 <= b && i !== info.q);
      if (info.contextFile || !inSpan.length) covered = Array.from({ length: Math.max(0, b - a + 1) }, (_, k) => a - 1 + k);
    }
    const moving = movingFrom(strokes, frames, { pagesVersion: meta.pagesVersion, now: now() });
    const { offer, over } = chooseMore({ q: info.q, written, covered, withheldFrom: moving });
    return { frames, byPage, written, offer, over, moving };
  }

  function addPending(doc, info) {
    pending.delete(doc);
    pending.set(doc, info);
    while (pending.size > 2) pending.delete(pending.keys().next().value);
  }

  /// Bereitet zu einer Frage die weiteren Seiten vor und legt sie in qdir/weitere/ (vorher geleert). Gibt zurück:
  /// - {more: {pages, written, notReady, over, movingFrom, files: {N: {bytes, key}}, highest, drawn}}: Seitennummern ab
  ///   1; pages liegen als seite-<N>.pdf bereit, written sind alle beschriebenen außer der Frage und den schon gezeigten
  ///   (unter movingFrom), notReady bis zur Frist nicht gezeichnet, over über die 200 nächsten hinaus, highest die
  ///   letzte beschriebene Seite, drawn neu gezeichnet
  /// - {moreOff: Grund}: diesmal nicht (Grund fürs Protokoll), etwa „aus“, „Server ohne Route“, „Tageslimit erreicht“,
  ///   „Spiegel nicht fertig“, „Seitenstand anders“, „PDF zu alt“, „PDF-Hintergrund geht nicht“, „abgebrochen“
  /// - {}: sonst ist nichts geschrieben
  /// Fehler am Mac selbst (LOCAL_ERRORS) gehen weiter, ebenso unerwartete; Fehler des Servers werden zu moreOff
  function prepare(job, files, { qdir, dir, deadline = now() + 15000, isCancelled = () => false }) {
    return exclusive(async () => {
      const out = path.join(qdir, "weitere");
      fs.rmSync(out, { recursive: true, force: true });
      try {
        const r = await prepareInner(job, files, { dir, out, deadline, isCancelled });
        if (!r.more) fs.rmSync(out, { recursive: true, force: true });
        return r;
      } catch (e) {
        try {
          fs.rmSync(out, { recursive: true, force: true });
        } catch {}
        throw e;
      }
    });
  }

  async function prepareInner(job, files, { dir, out, deadline, isCancelled }) {
    const off = (why) => ({ moreOff: why });
    const cfg = config();
    const effort = job.effort === "thorough" ? "thorough" : "quick";
    if (!(cfg.morePages[effort] > 0)) return off("aus");
    const q = job.anchor?.page;
    if (!Number.isInteger(q) || q < 0) return off("Seite der Frage gelöscht");
    if (files.pdfOld) return off("PDF zu alt");
    const doc = job.doc?.id;
    if (typeof doc !== "string" || !DOC_ID.test(doc)) return off("Kennung ungültig");
    if (now() < noRouteUntil) return off("Server ohne Route");
    const isPDF = job.doc.kind === "pdf" || Boolean(job.doc.hasPDF);
    const local = Number(state.docs?.[doc]?.pdfVersion ?? job.doc.pdfVersion) || 0;
    const info = {
      q, pv: Number(job.pv) || 0, isPDF, pdfVersion: Math.max(0, Math.floor(local)), pdfPath: null,
      span: Array.isArray(files.span) && files.span.length === 2 ? files.span.map(Number) : null,
      contextFile: Boolean(files.contextFile),
    };
    info.spanEnd = info.span ? info.span[1] : 0;
    if (isPDF) {
      if (!files.pdf) return off("PDF fehlt");
      info.pdfPath = path.join(dir, files.pdf);
      const tested = await probeOK(deadline);
      if (tested !== true) return off(tested === null ? "PDF-Hintergrund nicht rechtzeitig geprüft" : "PDF-Hintergrund geht nicht");
    }
    const m = mirror(doc);
    m.used = now();
    addPending(doc, info);
    // Passt der Stand am Server nicht zur Frage, gleich aufhören (warm() holt den Rest später)
    const check = (meta) => {
      if ((Number(meta?.pagesVersion) || 0) !== info.pv) return "Seitenstand anders";
      if (isPDF && (Number(meta?.pdfVersion) || 0) !== info.pdfVersion) return "PDF zu alt";
      return null;
    };
    const pulled = await pull(m, { deadline, isCancelled, check });
    if (pulled.off) {
      if (pulled.off === "Dokument gelöscht") pending.delete(doc);
      else if (m.cursor) {
        writeStand(m);
        liftLocal(); // die Kopie ließ sich (bis zur Frist zum Teil) schreiben
      }
      return off(pulled.off);
    }
    writeStand(m);
    liftLocal(); // die Kopie ließ sich schreiben: warm() darf wieder (siehe localUntil)
    const mo = await model(m, info, deadline);
    if (mo.off) return off(mo.off);
    const highest = mo.written.length ? mo.written.at(-1) + 1 : 0;
    if (!mo.offer.length && !mo.over.length && mo.moving === null) return {};
    const ctx = { doc, isPDF, pdfVersion: info.pdfVersion, pdfPath: info.pdfPath, frames: mo.frames, byPage: mo.byPage };
    const r = await render(ctx, mo.offer, { deadline, isCancelled });
    if (r.cancelled) return off("abgebrochen");
    const pages = [...r.ready.keys()].sort((a, b) => a - b);
    const handed = {};
    if (pages.length) fs.mkdirSync(out, { recursive: true });
    for (const i of pages) {
      // Eine Kopie (unter APFS ein Klon), nie ein Verweis: Claude liest nur im Chat-Ordner
      const dest = path.join(out, `seite-${i + 1}.pdf`);
      fs.copyFileSync(r.ready.get(i).file, dest, fs.constants.COPYFILE_FICLONE);
      handed[i + 1] = { bytes: fs.statSync(dest).size, key: r.ready.get(i).key };
    }
    if (!r.notReady.length && m.complete) pending.delete(doc);
    const up = (list) => list.map((i) => i + 1).sort((a, b) => a - b);
    return {
      more: {
        pages: up(pages), written: up([...mo.offer, ...mo.over]), notReady: up(r.notReady), over: up(mo.over),
        movingFrom: mo.moving === null ? null : mo.moving + 1, files: handed, highest, drawn: r.drawn,
      },
    };
  }

  /// In Ruhe (keine Frage offen): für die letzten Dokumente einen unfertigen Spiegel weiterholen und noch nicht
  /// gezeichnete Seiten vorzeichnen (nur in seitenbilder/); hintergrund.js prüfen, wenn eine Frage es bis zu ihrer Frist
  /// nicht geschafft hat; von den Dokumenten `recent` (die mit den letzten Fragen, das neueste zuerst) eine fehlende
  /// oder unfertige Kopie der Striche holen. Hört auf, sobald shouldStop() gilt oder `signal` abbricht (dann auch mitten
  /// im Abruf oder in osascript: Lernwörter und Fragen warten nicht darauf), sonst nach einer Minute. Gibt true zurück,
  /// wenn die Minute mitten im Holen einer Kopie um war (der Helfer macht dann gleich weiter, nicht erst in Minuten)
  function warm(shouldStop = () => false, signal = null, recent = []) {
    return exclusive(async () => {
      const stopped = () => Boolean(shouldStop() || signal?.aborted);
      const deadline = now() + 60000;
      if (now() < noRouteUntil || now() < localUntil || stopped()) return false;
      warming = { signal };
      try {
        if (probeLater && probe === null) {
          probeLater = false;
          await probeOK(deadline);
        }
        for (const [doc, info] of [...pending].reverse()) {
          if (stopped() || now() >= deadline) return false;
          const m = mirror(doc);
          if (!m.complete) {
            const r = await pull(m, { deadline, isCancelled: stopped });
            if (r.off) return r.off === "Spiegel nicht fertig";
          }
          const meta = m.meta || {};
          if ((Number(meta.pagesVersion) || 0) !== info.pv || (info.isPDF && ((Number(meta.pdfVersion) || 0) !== info.pdfVersion || probe !== true))) {
            pending.delete(doc);
            continue;
          }
          const mo = await model(m, info, deadline);
          if (mo.off) {
            if (stopped()) return false;
            pending.delete(doc);
            continue;
          }
          const ctx = { doc, isPDF: info.isPDF, pdfVersion: info.pdfVersion, pdfPath: info.pdfPath, frames: mo.frames, byPage: mo.byPage };
          const r = await render(ctx, mo.offer, { deadline, isCancelled: stopped });
          if (r.cancelled || stopped()) return false;
          if (r.notReady.length && deadline - now() <= 1000) {
            // Frist um: das nächste Mal weiter. Außer ein ganzer Stapel Hintergründe brachte keinen neuen (die Seite vorn
            // hängt, sie bleibt jetzt aus) und auch sonst keiner: Das versucht erst die nächste Frage zu diesem Dokument
            // wieder (braucht jede Seite zu lange, käme sonst jede Ruhepause mit einer Minute osascript wieder)
            if (r.stalled && !r.made) pending.delete(doc);
            return false;
          }
          if (r.drawn) log(`Weitere Seiten: ${r.drawn} ${r.drawn === 1 ? "Seite" : "Seiten"} von ${doc.slice(0, 8)} vorgezeichnet`);
          // Brauchte ein Stapel Hintergründe nur zu lange, kamen aber neue dazu (ein langsames PDF; neu gezeichnete Seiten
          // mit Hintergrund zählen nicht): die nächste Ruhepause zeichnet weiter. Sonst fehlt nur, wessen Hintergrund
          // nicht ging, ohne einen neuen hing (die Seite vorn bleibt jetzt aus) oder gerade ausgelassen ist: Das
          // versucht erst die nächste Frage zu diesem Dokument wieder
          if (!(r.notReady.length && r.timedOut && r.made)) pending.delete(doc);
        }
        // Gleich nach dem Start (Einrichten, Neustart des Mac): Fehlt die Kopie der Striche eines Dokuments mit den
        // letzten Fragen oder ist sie unfertig, jetzt holen. Die erste Frage dort wartete sonst darauf, bei einem großen
        // Dokument bis zu ihrer Frist und dann ohne weitere Seiten. Eine fertige Kopie holt erst die nächste Frage nach;
        // abgeschaltet (morePages 0 und 0) keine
        const { quick, thorough } = config().morePages;
        if (!(quick > 0 || thorough > 0)) return false;
        for (const doc of Array.isArray(recent) ? recent.slice(0, 2) : []) {
          if (stopped() || now() >= deadline) return false;
          if (typeof doc !== "string" || !DOC_ID.test(doc) || pending.has(doc) || gone.has(doc)) continue;
          if (readJSON(path.join(SPIEGEL, doc, "stand.json"))?.complete === true) continue;
          const r = await pull(mirror(doc), { deadline, isCancelled: stopped });
          if (r.off === "Dokument gelöscht") gone.add(doc);
          else if (r.off) return r.off === "Spiegel nicht fertig";
        }
        return false;
      } catch (e) {
        // Fehler am Mac selbst (etwa die Platte voll): eine Stunde nichts in Ruhe. Sonst läse jede Ruhepause dieselben
        // Zeilen am Server und würfe sie weg (eine Frage dagegen hält den Helfer an, siehe localPause in helfer.mjs)
        if (LOCAL_ERRORS.has(e?.code)) localUntil = now() + HOUR;
        throw e;
      } finally {
        warming = null;
      }
    });
  }

  /// Aufräumen: Spiegel und Seiten eines Dokuments, das 90 Tage nicht gebraucht wurde; gezeichnete Seiten und
  /// Hintergründe, die 30 Tage nicht gebraucht wurden; je Dokument höchstens 300 MB (die ältesten zuerst weg); liegen
  /// gebliebene Zwischendateien nach einem Tag
  function prune() {
    return exclusive(async () => {
      const t = now();
      try {
        for (const doc of listDir(SPIEGEL)) {
          if (!DOC_ID.test(doc)) continue;
          const stand = readJSON(path.join(SPIEGEL, doc, "stand.json"));
          let used = isNum(stand?.used) ? stand.used : 0;
          if (!used) {
            try {
              used = fs.statSync(path.join(SPIEGEL, doc)).mtimeMs;
            } catch {}
          }
          if (t - used > 90 * DAY) {
            dropDoc(doc);
            log(`Weitere Seiten: Spiegel ${doc.slice(0, 8)} seit 90 Tagen nicht gebraucht, entfernt`);
          } else {
            dropStaleTmp(path.join(SPIEGEL, doc), ["striche.ndjson", "stand.json"], t);
          }
        }
        dropStaleTmp(HOME, ["hintergrund.js"], t);
        for (const doc of listDir(BILDER)) {
          if (!DOC_ID.test(doc)) continue;
          const base = path.join(BILDER, doc);
          const all = [];
          for (const name of listDir(base)) {
            const p = path.join(base, name);
            let st;
            try {
              st = fs.statSync(p);
            } catch {
              continue;
            }
            if (st.isDirectory()) {
              for (const sub of listDir(p)) {
                try {
                  const s2 = fs.statSync(path.join(p, sub));
                  if (s2.isFile()) all.push({ file: path.join(p, sub), size: s2.size, t: s2.mtimeMs });
                } catch {}
              }
            } else if (st.isFile()) {
              all.push({ file: p, size: st.size, t: st.mtimeMs });
            }
          }
          let total = 0;
          const keep = [];
          for (const f of all) {
            if (t - f.t > 30 * DAY || (f.file.endsWith(".tmp") && t - f.t > DAY)) fs.rmSync(f.file, { force: true });
            else {
              keep.push(f);
              total += f.size;
            }
          }
          keep.sort((a, b) => a.t - b.t);
          for (const f of keep) {
            if (total <= 300e6) break;
            fs.rmSync(f.file, { force: true });
            total -= f.size;
          }
          // Ohne Spiegel und ohne Seiten: der leere Ordner
          if (!fs.existsSync(path.join(SPIEGEL, doc)) && !listDir(base).some((n) => !/^v\d+$/.test(n) || listDir(path.join(base, n)).length)) {
            fs.rmSync(base, { recursive: true, force: true });
          }
        }
      } catch (e) {
        log("Weitere Seiten: Aufräumen gescheitert:", e.message);
      }
    });
  }

  return { prepare, warm, prune };
}
