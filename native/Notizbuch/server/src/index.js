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

const CHUNK = 1024 * 1024;

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
    if (!url.pathname.startsWith("/api/")) {
      return new Response("Notizbuch-Server läuft.\n", { headers: { "content-type": "text/plain; charset=utf-8" } });
    }
    const auth = request.headers.get("authorization") || "";
    if (!env.SECRET || !sameSecret(auth, `Bearer ${env.SECRET}`)) {
      return json({ error: "Falscher oder fehlender Schlüssel" }, 401);
    }
    const store = env.STORE.get(env.STORE.idFromName("main"));
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
      const [, area, id, sub] = parts;

      if (area === "library" && !id && method === "GET") return json({ docs: this.library() });
      if (area === "library" && id && method === "PUT") return json(this.putMeta(id, await request.json()));

      if (area === "doc" && id && sub === "sync" && method === "POST") return json(this.syncDoc(id, await request.json()));

      if (area === "pdf" && id && method === "PUT") {
        this.putBlob(`pdf/${id}`, await request.arrayBuffer(), "application/pdf");
        return json({ ok: true });
      }
      if (area === "pdf" && id && method === "GET") return this.blobResponse(`pdf/${id}`);

      if (area === "inbox" && !id && method === "POST") return json(await this.inbox(request, url));

      if (area === "outbox" && !id && method === "GET") return json({ files: this.listOutbox() });
      if (area === "outbox" && id && method === "PUT") {
        this.putBlob(`outbox/${id}`, await request.arrayBuffer(), request.headers.get("content-type"));
        return json({ ok: true });
      }
      if (area === "outbox" && id && method === "GET") return this.blobResponse(`outbox/${id}`);
      if (area === "outbox" && id && method === "DELETE") {
        this.deleteBlob(`outbox/${id}`);
        return json({ ok: true });
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

  /// Letzte Änderung gewinnt; gelöschte Dokumente bleiben als Grabstein (deleted: true)
  putMeta(id, meta) {
    if (typeof meta !== "object" || meta === null) throw new Error("meta fehlt");
    meta.id = id;
    const modified = Number(meta.modified) || 0;
    const existing = this.sql.exec("SELECT meta, modified FROM docs WHERE id = ?", id).toArray()[0];
    if (existing && existing.modified > modified) return JSON.parse(existing.meta);
    const clean = { ...meta };
    delete clean.strokeSeq;
    delete clean.hasPDF;
    this.sql.exec(
      "INSERT OR REPLACE INTO docs (id, meta, modified, seq) VALUES (?, ?, ?, ?)",
      id, JSON.stringify(clean), modified, this.nextSeq(),
    );
    if (clean.deleted) {
      this.sql.exec("DELETE FROM strokes WHERE doc = ?", id);
      this.deleteBlob(`pdf/${id}`);
    }
    return clean;
  }

  /// body: { since, add: [{ id, data }], remove: [id] }  →  { seq, changes: [{ id, data | null }] }
  syncDoc(doc, body) {
    const since = Number(body.since) || 0;
    this.ctx.storage.transactionSync(() => {
      for (const s of body.add || []) {
        if (typeof s.id !== "string" || typeof s.data !== "string") continue;
        this.sql.exec(
          "INSERT OR REPLACE INTO strokes (doc, id, data, alive, seq) VALUES (?, ?, ?, 1, ?)",
          doc, s.id, s.data, this.nextSeq(),
        );
      }
      for (const id of body.remove || []) {
        if (typeof id !== "string") continue;
        this.sql.exec(
          "INSERT OR REPLACE INTO strokes (doc, id, data, alive, seq) VALUES (?, ?, NULL, 0, ?)",
          doc, id, this.nextSeq(),
        );
      }
    });
    const rows = this.sql
      .exec("SELECT id, data, alive, seq FROM strokes WHERE doc = ? AND seq > ? ORDER BY seq", doc, since)
      .toArray();
    const max = this.sql.exec("SELECT MAX(seq) AS s FROM strokes WHERE doc = ?", doc).one().s || 0;
    return { seq: max, changes: rows.map((r) => ({ id: r.id, data: r.alive ? r.data : null })) };
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
    this.putMeta(id, { id, title, kind: "pdf", created: now, modified: now, pageCount: 0, layoutVersion: 2 });
    return { id, title };
  }

  listOutbox() {
    return this.sql
      .exec("SELECT key, size, type, created FROM blobmeta WHERE key LIKE 'outbox/%' ORDER BY created DESC")
      .toArray()
      .map((r) => ({ name: r.key.slice("outbox/".length), size: r.size, type: r.type, created: r.created }));
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
