// Notizbuch-Server: Sync zwischen iPad und iPhone und ein Briefkasten für KI-Agenten.
//
// Alles liegt in einem einzigen Durable Object mit SQLite-Speicher (gratis im Workers-Free-Tarif):
//   docs     Metadaten der Dokumente (wie meta.json in der App), "letzte Änderung gewinnt"
//   strokes  jeder Strich mit stabiler ID; Löschen setzt alive = 0 (Grabstein), so gibt es keine Konflikte
//   blobs    PDFs und Ausgang-Dateien, in 1-MB-Stücken
// Jede Änderung bekommt eine fortlaufende Nummer (seq). Geräte fragen „alles seit seq X“.
//
// Alle /api-Adressen brauchen den Header  Authorization: Bearer <SECRET>.

import { DurableObject } from "cloudflare:workers";
import viewerHTML from "./viewer.html";

const CHUNK = 1024 * 1024;
const RECIPIENTS = ["claude", "chatgpt"];
// Zeigestift-Farben der Gäste im Browser, je Gast eine andere. Lila (iPad) und Pink (iPhone) gehören den Apps.
const GUEST_COLORS = ["#00a8e8", "#ff7a00", "#00b386", "#ff3b30", "#2f6bff", "#e0a800"];
const isColor = (c) => typeof c === "string" && /^#[0-9a-fA-F]{6}$/.test(c);

const json = (data, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });

function sameSecret(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const store = env.STORE.get(env.STORE.idFromName("main"));
    // Geteilte Dokumente: /s/<token> ist die Web-Ansicht für Gäste, der Token ist die Berechtigung
    if (/^\/s\/[A-Za-z0-9_-]{8,}\/?$/.test(url.pathname)) {
      return new Response(viewerHTML, {
        headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
      });
    }
    if (url.pathname.startsWith("/s/")) return store.fetch(request);
    if (!url.pathname.startsWith("/api/")) {
      return new Response("Notizbuch-Server läuft.\n", { headers: { "content-type": "text/plain; charset=utf-8" } });
    }
    const auth = request.headers.get("authorization") || "";
    if (!env.SECRET || !sameSecret(auth, `Bearer ${env.SECRET}`)) {
      return json({ error: "Falscher oder fehlender Schlüssel" }, 401);
    }
    return store.fetch(request);
  },
};

export class Store extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS counter (k TEXT PRIMARY KEY, v INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS docs (id TEXT PRIMARY KEY, meta TEXT NOT NULL, modified REAL NOT NULL, seq INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS strokes (doc TEXT NOT NULL, id TEXT NOT NULL, data TEXT, alive INTEGER NOT NULL, seq INTEGER NOT NULL,
                                          PRIMARY KEY (doc, id));
      CREATE INDEX IF NOT EXISTS strokes_seq ON strokes (doc, seq);
      CREATE TABLE IF NOT EXISTS blobmeta (key TEXT PRIMARY KEY, size INTEGER NOT NULL, type TEXT, created REAL NOT NULL);
      CREATE TABLE IF NOT EXISTS shares (token TEXT PRIMARY KEY, doc TEXT NOT NULL, created REAL NOT NULL);
      CREATE TABLE IF NOT EXISTS blobs (key TEXT NOT NULL, part INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY (key, part));
    `);
  }

  nextSeq() {
    const row = this.sql
      .exec("INSERT INTO counter (k, v) VALUES ('seq', 1) ON CONFLICT(k) DO UPDATE SET v = v + 1 RETURNING v")
      .one();
    return row.v;
  }

  async fetch(request) {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean).map(decodeURIComponent); // ["api", ...]
    const method = request.method;
    try {
      if (parts[0] === "s") return this.guest(request, parts[1], parts[2]);
      const [, area, id, sub] = parts;

      if (area === "doc" && id && sub === "ws") return this.accept(request, id, "app");
      if (area === "share" && id && method === "POST") return json({ token: this.shareToken(id) });
      if (area === "share" && id && method === "DELETE") {
        this.sql.exec("DELETE FROM shares WHERE doc = ?", id);
        for (const ws of this.ctx.getWebSockets(`guest:${id}`)) ws.close(4001, "Teilen beendet");
        return json({ ok: true });
      }

      if (area === "library" && !id && method === "GET") return json({ docs: this.library() });
      if (area === "library" && id && method === "PUT") return json(this.putMeta(id, await request.json()));

      if (area === "doc" && id && sub === "sync" && method === "POST") return json(this.syncDoc(id, await request.json()));

      if (area === "pdf" && id && method === "PUT") {
        this.putBlob(`pdf/${id}`, await request.arrayBuffer(), "application/pdf");
        return json({ ok: true });
      }
      if (area === "pdf" && id && method === "GET") return this.blobResponse(`pdf/${id}`);

      if (area === "inbox" && !id && method === "POST") return json(await this.inbox(request, url));

      // Ausgang je Empfänger: /api/outbox/claude/… und /api/outbox/chatgpt/…
      if (area === "outbox") {
        if (!id && method === "GET") return json({ files: this.listOutbox(null) });
        if (!RECIPIENTS.includes(id)) return json({ error: `Empfänger muss ${RECIPIENTS.join(" oder ")} sein` }, 400);
        if (!sub && method === "GET") return json({ files: this.listOutbox(id) });
        const key = `outbox/${id}/${sub}`;
        if (sub && method === "PUT") {
          this.putBlob(key, await request.arrayBuffer(), request.headers.get("content-type"));
          return json({ ok: true });
        }
        if (sub && method === "GET") return this.blobResponse(key);
        if (sub && method === "DELETE") {
          this.deleteBlob(key);
          return json({ ok: true });
        }
      }
      return json({ error: "Unbekannte Adresse" }, 404);
    } catch (e) {
      return json({ error: String(e && e.message ? e.message : e) }, 400);
    }
  }

  // ---------- Dokumente ----------

  library() {
    const strokeSeqs = new Map(
      this.sql.exec("SELECT doc, MAX(seq) AS s FROM strokes GROUP BY doc").toArray().map((r) => [r.doc, r.s]),
    );
    return this.sql.exec("SELECT id, meta FROM docs").toArray().map((r) => ({
      ...JSON.parse(r.meta),
      strokeSeq: strokeSeqs.get(r.id) || 0,
      hasPDF: this.sql.exec("SELECT 1 FROM blobmeta WHERE key = ?", `pdf/${r.id}`).toArray().length > 0,
    }));
  }

  /// Letzte Änderung gewinnt (modified); gelöschte Dokumente bleiben als Grabstein (deleted: true).
  /// Seitenzahl und PDF-Version folgen dagegen der neuesten Seitenänderung (pagesVersion, pdfVersion)
  /// und gehen nie zurück: Ein Gerät, das von der Seitenänderung noch nichts weiß, darf sie nicht überschreiben.
  putMeta(id, meta) {
    if (typeof meta !== "object" || meta === null) throw new Error("meta fehlt");
    meta.id = id;
    const modified = Number(meta.modified) || 0;
    const existing = this.sql.exec("SELECT meta, modified FROM docs WHERE id = ?", id).toArray()[0];
    const before = existing ? JSON.parse(existing.meta) : null;
    let result;
    if (existing && existing.modified > modified) {
      // Älterer Stand: höchstens eine neuere Seitenänderung bzw. PDF-Version übernehmen
      if (before.deleted || !newerStructure(meta, before)) return before;
      result = { ...before };
      takeStructure(result, meta);
      this.sql.exec("UPDATE docs SET meta = ?, seq = ? WHERE id = ?", JSON.stringify(result), this.nextSeq(), id);
    } else {
      result = { ...meta };
      delete result.strokeSeq;
      delete result.hasPDF;
      if (before && !result.deleted) takeStructure(result, before);
      this.sql.exec(
        "INSERT OR REPLACE INTO docs (id, meta, modified, seq) VALUES (?, ?, ?, ?)",
        id, JSON.stringify(result), modified, this.nextSeq(),
      );
      if (result.deleted) {
        this.sql.exec("DELETE FROM strokes WHERE doc = ?", id);
        this.deleteBlob(`pdf/${id}`);
      }
    }
    // Seiten gelöscht oder eingefügt: offene Ansichten bauen ihre Seiten neu auf
    if (before && !result.deleted && newerStructure(result, before)) this.broadcast(id, { type: "pages" });
    return result;
  }

  /// body: { since, add: [{ id, data }], remove: [id] }  →  { seq, changes: [{ id, data | null }] }
  /// Was die Anfrage selbst schreibt, kommt nicht zurück (sonst ginge nach einer Seitenänderung alles doppelt hin und her).
  syncDoc(doc, body) {
    const since = Number(body.since) || 0;
    const upTo = this.sql.exec("SELECT v FROM counter WHERE k = 'seq'").toArray()[0]?.v || 0;
    this.applyOps(doc, body.add || [], body.remove || []);
    const rows = this.sql
      .exec("SELECT id, data, alive, seq FROM strokes WHERE doc = ? AND seq > ? AND seq <= ? ORDER BY seq", doc, since, upTo)
      .toArray();
    const max = this.sql.exec("SELECT MAX(seq) AS s FROM strokes WHERE doc = ?", doc).one().s || 0;
    return { seq: max, changes: rows.map((r) => ({ id: r.id, data: r.alive ? r.data : null })) };
  }

  /// Schreibt Striche und meldet sie allen, die das Dokument gerade live offen haben
  applyOps(doc, add, remove) {
    const changes = [];
    let last = 0;
    this.ctx.storage.transactionSync(() => {
      for (const s of add) {
        if (!s || typeof s.id !== "string" || typeof s.data !== "string" || s.data.length > 500000) continue;
        last = this.nextSeq();
        this.sql.exec(
          "INSERT OR REPLACE INTO strokes (doc, id, data, alive, seq) VALUES (?, ?, ?, 1, ?)",
          doc, s.id, s.data, last,
        );
        changes.push({ id: s.id, data: s.data, seq: last });
      }
      for (const id of remove) {
        if (typeof id !== "string") continue;
        last = this.nextSeq();
        this.sql.exec(
          "INSERT OR REPLACE INTO strokes (doc, id, data, alive, seq) VALUES (?, ?, NULL, 0, ?)",
          doc, id, last,
        );
        changes.push({ id, data: null, seq: last });
      }
    });
    if (!changes.length) return;
    // Apps holen die Striche selbst per Sync: ein kurzer Hinweis genügt. Mit der neuen Änderungsnummer:
    // Wer sie schon kennt (der Absender selbst), muss nicht nachfragen.
    this.broadcast(doc, { type: "changes", changes: [], seq: last }, `app:${doc}`);
    // Browser bekommen die Striche mit, in Teilen von höchstens etwa 500 KB
    // (nach einer Seitenänderung sind es alle Striche darunter auf einmal)
    let part = [], size = 0;
    const flush = () => {
      if (part.length) this.broadcast(doc, { type: "changes", changes: part }, `guest:${doc}`);
      part = [];
      size = 0;
    };
    for (const c of changes) {
      const n = (c.data ? c.data.length : 0) + c.id.length + 40;
      if (size + n > 500000) flush();
      part.push(c);
      size += n;
    }
    flush();
  }

  // ---------- Live: WebSockets (Hibernation-API) ----------
  // Tags: doc:<id> für alle, app:<id> bzw. guest:<id> je nach Rolle

  accept(request, doc, role) {
    if (request.headers.get("upgrade") !== "websocket") return json({ error: "WebSocket erwartet" }, 426);
    const pair = new WebSocketPair();
    const color = role === "guest" ? this.guestColor(doc, new URL(request.url).searchParams.get("c")) : null;
    this.ctx.acceptWebSocket(pair[1], [`doc:${doc}`, `${role}:${doc}`]);
    if (color) pair[1].serializeAttachment({ color });
    if (role === "guest") {
      // Eigene Zeigestift-Farbe (gilt, solange die Verbindung steht)
      pair[1].send(JSON.stringify({ type: "you", color }));
      if (this.lastView?.[doc]) pair[1].send(JSON.stringify(this.lastView[doc]));
      this.presence(doc);
    } else {
      // Die App erfährt die Gästezahl auch, wenn sie ein schon geteiltes Dokument neu öffnet
      pair[1].send(JSON.stringify({ type: "presence", guests: this.ctx.getWebSockets(`guest:${doc}`).length }));
    }
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  /// Farbe für einen neuen Gast: die gewünschte (die er vor einer Unterbrechung hatte), wenn sie frei ist,
  /// sonst die erste freie; sind alle vergeben, reihum
  guestColor(doc, wanted) {
    const used = new Set();
    for (const ws of this.ctx.getWebSockets(`guest:${doc}`)) {
      const c = ws.deserializeAttachment()?.color;
      if (c) used.add(c);
    }
    const want = wanted ? "#" + String(wanted).replace(/^#/, "").toLowerCase() : null;
    if (want && GUEST_COLORS.includes(want) && !used.has(want)) return want;
    return GUEST_COLORS.find((c) => !used.has(c)) || GUEST_COLORS[used.size % GUEST_COLORS.length];
  }

  broadcast(doc, msg, tag = `doc:${doc}`) {
    const text = JSON.stringify(msg);
    for (const ws of this.ctx.getWebSockets(tag)) {
      try { ws.send(text); } catch {}
    }
  }

  presence(doc, leaving = null) {
    const guests = this.ctx.getWebSockets(`guest:${doc}`).filter((ws) => ws !== leaving).length;
    this.broadcast(doc, { type: "presence", guests });
  }

  webSocketMessage(ws, message) {
    const tags = this.ctx.getTags(ws);
    const docTag = tags.find((t) => t.startsWith("doc:"));
    if (!docTag || typeof message !== "string") return;
    const doc = docTag.slice(4);
    let msg;
    try { msg = JSON.parse(message); } catch { return; }
    if (tags.includes(`app:${doc}`) && msg.type === "view") {
      const view = { type: "view", y0: Number(msg.y0) || 0, y1: Number(msg.y1) || 0 };
      this.lastView = this.lastView || {};
      this.lastView[doc] = view;
      this.broadcast(doc, view, `guest:${doc}`);
    } else if (msg.type === "pointer" && typeof msg.id === "string" && Array.isArray(msg.pts)) {
      // Zeigestift: nur weiterreichen, nie speichern
      const pts = msg.pts.slice(0, 4000)
        .filter((p) => Array.isArray(p) && p.length >= 2)
        .map((p) => [Number(p[0]) || 0, Number(p[1]) || 0]);
      // Farbe: Gäste zeigen in der Farbe, die der Server ihnen gegeben hat, Apps in ihrer eigenen
      const own = ws.deserializeAttachment()?.color;
      const color = isColor(own) ? own : isColor(msg.color) ? msg.color.toLowerCase() : undefined;
      const out = JSON.stringify({
        type: "pointer", id: msg.id.slice(0, 64), from: String(msg.from || "").slice(0, 64), end: !!msg.end, pts, color,
      });
      for (const other of this.ctx.getWebSockets(docTag)) {
        if (other !== ws) try { other.send(out); } catch {}
      }
    } else if (tags.includes(`guest:${doc}`) && msg.type === "add" && msg.stroke) {
      this.applyOps(doc, [msg.stroke], []);
    } else if (tags.includes(`guest:${doc}`) && msg.type === "remove" && typeof msg.id === "string") {
      this.applyOps(doc, [], [msg.id]);
    }
  }

  webSocketClose(ws) {
    const tag = this.ctx.getTags(ws).find((t) => t.startsWith("guest:"));
    if (tag) this.presence(tag.slice(6), ws);
  }

  webSocketError(ws) {
    this.webSocketClose(ws);
  }

  // ---------- Teilen ----------

  shareToken(doc) {
    const existing = this.sql.exec("SELECT token FROM shares WHERE doc = ?", doc).toArray()[0];
    if (existing) return existing.token;
    const bytes = crypto.getRandomValues(new Uint8Array(18));
    const token = btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    this.sql.exec("INSERT INTO shares (token, doc, created) VALUES (?, ?, ?)", token, doc, Date.now() / 1000);
    return token;
  }

  /// Gast-Zugriffe: /s/<token>/data, /s/<token>/pdf, /s/<token>/ws
  guest(request, token, what) {
    const share = this.sql.exec("SELECT doc FROM shares WHERE token = ?", token || "").toArray()[0];
    if (!share) return json({ error: "Dieser Link ist nicht (mehr) gültig." }, 404);
    const doc = share.doc;
    if (what === "ws") return this.accept(request, doc, "guest");
    if (what === "pdf") return this.blobResponse(`pdf/${doc}`);
    if (what === "data") {
      const row = this.sql.exec("SELECT meta FROM docs WHERE id = ?", doc).toArray()[0];
      const meta = row ? JSON.parse(row.meta) : { title: "Notizbuch", kind: "notebook", pageCount: 1 };
      const strokes = this.sql
        .exec("SELECT id, data FROM strokes WHERE doc = ? AND alive = 1 ORDER BY seq", doc)
        .toArray();
      // Stand dieser Momentaufnahme: Live-Änderungen bis hierher sind darin schon enthalten
      const seq = this.sql.exec("SELECT MAX(seq) AS s FROM strokes WHERE doc = ?", doc).one().s || 0;
      return json({
        title: meta.title, kind: meta.kind, pageCount: meta.pageCount || 1,
        pdfVersion: meta.pdfVersion || 0, pagesVersion: meta.pagesVersion || 0, seq, strokes,
      });
    }
    return json({ error: "Unbekannte Adresse" }, 404);
  }

  // ---------- Briefkasten ----------

  /// Ein PDF in den Eingang: wird ein neues Dokument, das auf allen Geräten erscheint
  async inbox(request, url) {
    const bytes = await request.arrayBuffer();
    const head = new Uint8Array(bytes.slice(0, 5));
    if (String.fromCharCode(...head) !== "%PDF-") throw new Error("Das ist kein PDF");
    const id = crypto.randomUUID().toUpperCase();
    const now = Date.now() / 1000;
    const title = (url.searchParams.get("title") || "Aus dem Eingang").slice(0, 200);
    this.putBlob(`pdf/${id}`, bytes, "application/pdf");
    // Was Claude oder ChatGPT schicken, landet im Ordner „temp“ (die App löscht es dort nach 2 Wochen)
    this.putMeta(id, { id, title, kind: "pdf", created: now, modified: now, pageCount: 0, layoutVersion: 2, folder: "temp" });
    return { id, title };
  }

  listOutbox(to) {
    const prefix = to ? `outbox/${to}/` : "outbox/";
    return this.sql
      .exec("SELECT key, size, type, created FROM blobmeta WHERE substr(key, 1, ?) = ? ORDER BY created DESC",
        prefix.length, prefix)
      .toArray()
      .map((r) => {
        const [, recipient, ...rest] = r.key.split("/");
        return { to: recipient, name: rest.join("/"), size: r.size, type: r.type, created: r.created };
      });
  }

  // ---------- Dateien in Stücken ----------

  putBlob(key, buffer, type) {
    if (!buffer || buffer.byteLength === 0) throw new Error("Leere Datei");
    this.ctx.storage.transactionSync(() => {
      this.sql.exec("DELETE FROM blobs WHERE key = ?", key);
      for (let off = 0, part = 0; off < buffer.byteLength; off += CHUNK, part++) {
        this.sql.exec("INSERT INTO blobs (key, part, data) VALUES (?, ?, ?)", key, part, buffer.slice(off, off + CHUNK));
      }
      this.sql.exec(
        "INSERT OR REPLACE INTO blobmeta (key, size, type, created) VALUES (?, ?, ?, ?)",
        key, buffer.byteLength, type || "application/octet-stream", Date.now() / 1000,
      );
    });
  }

  deleteBlob(key) {
    this.sql.exec("DELETE FROM blobs WHERE key = ?", key);
    this.sql.exec("DELETE FROM blobmeta WHERE key = ?", key);
  }

  blobResponse(key) {
    const meta = this.sql.exec("SELECT size, type FROM blobmeta WHERE key = ?", key).toArray()[0];
    if (!meta) return json({ error: "Nicht gefunden" }, 404);
    const out = new Uint8Array(meta.size);
    let off = 0;
    for (const r of this.sql.exec("SELECT data FROM blobs WHERE key = ? ORDER BY part", key)) {
      const chunk = new Uint8Array(r.data);
      out.set(chunk, off);
      off += chunk.byteLength;
    }
    return new Response(out, { headers: { "content-type": meta.type || "application/octet-stream" } });
  }
}

// Seitenänderungen (löschen, einfügen) tragen eine eigene Version: pagesVersion für Seitenzahl und
// Reihenfolge, pdfVersion für das PDF selbst. Beide gehen nie zurück.
function newerStructure(a, b) {
  return (Number(a.pagesVersion) || 0) > (Number(b.pagesVersion) || 0) || (Number(a.pdfVersion) || 0) > (Number(b.pdfVersion) || 0);
}

/// Übernimmt in `target` die Seitenangaben aus `other`, wo sie neuer sind
function takeStructure(target, other) {
  if ((Number(other.pagesVersion) || 0) > (Number(target.pagesVersion) || 0)) {
    target.pagesVersion = Number(other.pagesVersion);
    target.pageCount = other.pageCount;
  }
  if ((Number(other.pdfVersion) || 0) > (Number(target.pdfVersion) || 0)) target.pdfVersion = Number(other.pdfVersion);
}
