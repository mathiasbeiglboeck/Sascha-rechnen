// Notizbuch-Server: Sync zwischen iPad und iPhone und ein Briefkasten für KI-Agenten.
//
// Alles liegt in einem einzigen Durable Object mit SQLite-Speicher (gratis im Workers-Free-Tarif):
//   docs     Metadaten der Dokumente (wie meta.json in der App), "letzte Änderung gewinnt"
//   strokes  jeder Strich mit stabiler ID; Löschen setzt alive = 0 (Grabstein), so gibt es keine Konflikte
//   blobs    PDFs und Ausgang-Dateien, in 1-MB-Stücken
//   asks     Fragen an Claude („Claude fragen“ im Lasso-Menü) samt Antwort; die Bilder der Frage liegen in blobs,
//            bis sie beantwortet ist. Ein Helfer am Mac holt sie ab (er bekommt neue sofort über /api/asks/ws)
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
// Fragen an Claude: höchstens so viele offene auf einmal (schützt die Nutzung am Mac vor einer Schleife in der App)
const MAX_OPEN_ASKS = 50;
const MAX_QUESTION_BYTES = 4 * 1024 * 1024;
const MAX_PAGE_BYTES = 8 * 1024 * 1024;
const MAX_ANSWER_CHARS = 200000;
// Markdown im Eingang (die App setzt es auf A4-Seiten): höchstens so groß
const MAX_MARKDOWN_BYTES = 512 * 1024;
const EFFORTS = ["quick", "thorough"];
// Frist, in der der Helfer eine übernommene Frage beantwortet (er kann sie verlängern), in Sekunden
const ASK_LEASE = 900;
// Läuft die Frist einer übernommenen Frage so oft ab, ohne dass eine Antwort kommt, gilt sie als gescheitert
const MAX_ASK_RETRIES = 3;
const UUID_RE = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/i;

const json = (data, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
/// Fehler mit Kennung: So unterscheiden App und Helfer sie von der 404 eines älteren Servers ohne diese Adressen
const fail = (error, code, status) => json({ error, code }, status);

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
      CREATE TABLE IF NOT EXISTS asks (id TEXT PRIMARY KEY, doc TEXT NOT NULL, status TEXT NOT NULL, anchor TEXT NOT NULL,
                                       pv INTEGER NOT NULL DEFAULT 0, effort TEXT NOT NULL DEFAULT 'quick',
                                       created REAL NOT NULL, updated REAL NOT NULL, lease REAL NOT NULL DEFAULT 0,
                                       claim TEXT, retries INTEGER NOT NULL DEFAULT 0, answer TEXT, note TEXT, info TEXT,
                                       v INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS asks_doc ON asks (doc);
      CREATE INDEX IF NOT EXISTS asks_status ON asks (status);
      CREATE TABLE IF NOT EXISTS asks_gone (id TEXT PRIMARY KEY, t REAL NOT NULL);
      CREATE INDEX IF NOT EXISTS asks_gone_t ON asks_gone (t);
    `);
    // Lebenszeichen des Helfers am Mac: beantwortet, ohne das Objekt zu wecken (kostet so gut wie nichts)
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
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
      const [, area, id, sub, extra] = parts;

      if (area === "doc" && id && sub === "ws") return this.accept(request, id, "app");

      // Fragen an Claude. Die App: Liste je Dokument, neue Frage, Markierung löschen, Stellen nach Seitenänderungen
      if (area === "doc" && id && sub === "asks") {
        if (!extra && method === "GET") return json(this.docAsks(id));
        if (!extra && method === "PATCH") return json(this.moveAsks(id, await request.json()));
        if (extra && method === "PUT") return await this.createAsk(request, id, extra);
        if (extra && method === "DELETE") return json(this.deleteAsk(id, extra));
      }
      // Der Helfer am Mac: wartet über den WebSocket, holt offene Fragen, übernimmt eine, lädt ihre Bilder, antwortet
      if (area === "asks") {
        if (id === "ws" && !sub) return this.acceptHelper(request);
        if (id === "open" && !sub && method === "GET") return json(this.openAsks());
        if (id && sub === "claim" && method === "POST") return await this.claimAsk(id, request);
        if (id && (sub === "question" || sub === "page") && method === "GET") return this.blobResponse(`ask/${id}/${sub}`);
        if (id && sub === "answer" && method === "PUT") return await this.answerAsk(id, request, url);
      }
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
        const bytes = await request.arrayBuffer();
        // Gesetztes Markdown aus dem Eingang: Es gilt das PDF des ersten Geräts (siehe putFirstPDF)
        if (url.searchParams.get("ifMissing") === "1") return json(this.putFirstPDF(id, bytes));
        this.putBlob(`pdf/${id}`, bytes, "application/pdf");
        return json({ ok: true });
      }
      if (area === "pdf" && id && method === "GET") return this.blobResponse(`pdf/${id}`);
      // Das Markdown eines Dokuments aus dem Eingang (die App setzt es auf Seiten)
      if (area === "md" && id && method === "GET") return this.blobResponse(`md/${id}`);

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
    // Höchste Änderungsnummer je Dokument einzeln über den Index (doc, seq): eine gelesene Zeile je Dokument.
    // Ein GROUP BY über alle Striche las bei jedem Abgleich der Bibliothek (alle 20 s je Gerät) jeden Strich samt
    // Grabsteinen und erschöpfte so das Tageslimit des Gratis-Tarifs (5 Millionen gelesene Zeilen am Tag).
    return this.sql.exec("SELECT id, meta FROM docs").toArray().map((r) => ({
      ...JSON.parse(r.meta),
      strokeSeq: this.sql.exec("SELECT MAX(seq) AS s FROM strokes WHERE doc = ?", r.id).one().s || 0,
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
        this.deleteBlob(`md/${id}`);
        this.deleteDocAsks(id);
      }
    }
    // Seiten gelöscht oder eingefügt: offene Ansichten bauen ihre Seiten neu auf. Ältere Apps schicken keine
    // Seitenversion; bei ihnen zeigt wie früher eine kleinere (gespeicherte) Seitenzahl das Löschen an
    const legacyDelete = !("pagesVersion" in meta) && (Number(result.pageCount) || 0) < (Number(before?.pageCount) || 0);
    if (before && !result.deleted && (newerStructure(result, before) || legacyDelete)) {
      // Mit dem neuen Seitenstand: Wer ihn schon hat (das Gerät, das die Seiten geändert hat), muss nichts tun
      const pagesVersion = Number(result.pagesVersion) || 0, pdfVersion = Number(result.pdfVersion) || 0;
      this.broadcast(id, { type: "pages", pagesVersion, pdfVersion });
    }
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
    if (!add.length && !remove.length) return; // Abfrage ohne eigene Änderungen (die häufigste): nichts zu lesen
    const changes = [];
    let last = 0;
    this.ctx.storage.transactionSync(() => {
      // Änderungsnummern am Stück vergeben und den Zähler nur einmal schreiben: Jede geschriebene Zeile zählt gegen
      // das Tageslimit des Gratis-Tarifs (100.000 am Tag), und nach einer Seitenänderung kommen Tausende Striche
      let seq = this.sql.exec("SELECT v FROM counter WHERE k = 'seq'").toArray()[0]?.v || 0;
      for (const s of add) {
        if (!s || typeof s.id !== "string" || typeof s.data !== "string" || s.data.length > 500000) continue;
        last = ++seq;
        // Vorhandene Zeilen ändern statt ersetzen: Ein Ersetzen schreibt jeden Index neu (eine Zeile mehr fürs Limit)
        this.sql.exec(
          "INSERT INTO strokes (doc, id, data, alive, seq) VALUES (?, ?, ?, 1, ?) " +
            "ON CONFLICT(doc, id) DO UPDATE SET data = excluded.data, alive = 1, seq = excluded.seq",
          doc, s.id, s.data, last,
        );
        changes.push({ id: s.id, data: s.data, seq: last });
      }
      for (const id of remove) {
        if (typeof id !== "string") continue;
        last = ++seq;
        this.sql.exec(
          "INSERT INTO strokes (doc, id, data, alive, seq) VALUES (?, ?, NULL, 0, ?) " +
            "ON CONFLICT(doc, id) DO UPDATE SET data = NULL, alive = 0, seq = excluded.seq",
          doc, id, last,
        );
        changes.push({ id, data: null, seq: last });
      }
      if (last) this.sql.exec("INSERT INTO counter (k, v) VALUES ('seq', ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v", last);
    });
    if (!changes.length) return;
    // Apps holen die Striche selbst per Sync: ein kurzer Hinweis genügt. Mit der neuen Änderungsnummer:
    // Wer sie schon kennt (der Absender selbst), muss nicht nachfragen.
    this.broadcast(doc, { type: "changes", changes: [], seq: last }, `app:${doc}`);
    // Browser bekommen die Striche mit (nach einer Seitenänderung sind es alle Striche darunter auf einmal)
    inParts(changes, (part) => this.broadcast(doc, { type: "changes", changes: part }, `guest:${doc}`));
  }

  /// Was ein Gast seit seinem Stand `since` verpasst hat (über den Index, nur die Zeilen danach). Haben sich
  /// inzwischen die Seiten geändert, nur der Hinweis darauf: Der Gast lädt dann ohnehin alles neu, und nach einer
  /// Seitenänderung wären es Tausende verschobene Striche, die er erst einzeln einarbeiten und dann verwerfen würde.
  missed(doc, params) {
    const row = this.sql.exec("SELECT meta FROM docs WHERE id = ?", doc).toArray()[0];
    const meta = row ? JSON.parse(row.meta) : {};
    if ((Number(meta.pagesVersion) || 0) !== (Number(params.get("pv")) || 0) ||
        (Number(meta.pdfVersion) || 0) !== (Number(params.get("dv")) || 0)) {
      return { pages: true, changes: [] };
    }
    const since = Number(params.get("since")) || 0;
    const changes = this.sql
      .exec("SELECT id, data, alive, seq FROM strokes WHERE doc = ? AND seq > ? ORDER BY seq", doc, since)
      .toArray()
      .map((r) => ({ id: r.id, data: r.alive ? r.data : null, seq: r.seq }));
    return { pages: false, changes };
  }

  /// Beim Verbinden: was der Gast seit seiner Momentaufnahme (/data) oder vor einer Unterbrechung verpasst hat.
  /// accept() läuft ohne Unterbrechung, dazwischen kann also nichts geschrieben werden, was weder hier noch live ankommt.
  catchUp(ws, doc, params) {
    const { pages, changes } = this.missed(doc, params);
    if (pages) ws.send(JSON.stringify({ type: "pages" }));
    inParts(changes, (part) => ws.send(JSON.stringify({ type: "changes", changes: part })));
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
      const params = new URL(request.url).searchParams;
      if (params.has("since")) this.catchUp(pair[1], doc, params);
      if (this.lastView?.[doc]) pair[1].send(JSON.stringify(this.lastView[doc]));
      this.presence(doc);
    } else {
      // Die App erfährt die Gästezahl auch, wenn sie ein schon geteiltes Dokument neu öffnet
      pair[1].send(JSON.stringify({ type: "presence", guests: this.ctx.getWebSockets(`guest:${doc}`).length }));
    }
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  /// Farbe für einen neuen Gast: die gewünschte (die er vor einer Unterbrechung hatte), wenn sie frei ist,
  /// sonst die am wenigsten vergebene (bei Gleichstand die erste in der Liste)
  guestColor(doc, wanted) {
    const count = new Map(GUEST_COLORS.map((c) => [c, 0]));
    for (const ws of this.ctx.getWebSockets(`guest:${doc}`)) {
      const c = ws.deserializeAttachment()?.color;
      if (count.has(c)) count.set(c, count.get(c) + 1);
    }
    const want = wanted ? "#" + String(wanted).replace(/^#/, "").toLowerCase() : null;
    if (want && count.get(want) === 0) return want;
    let best = GUEST_COLORS[0];
    for (const c of GUEST_COLORS) if (count.get(c) < count.get(best)) best = c;
    return best;
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

  /// Gast-Zugriffe: /s/<token>/data, /s/<token>/pdf, /s/<token>/ws, /s/<token>/changes
  guest(request, token, what) {
    const share = this.sql.exec("SELECT doc FROM shares WHERE token = ?", token || "").toArray()[0];
    if (!share) {
      // Browser verbinden nach einer Unterbrechung nur neu, ohne zu laden: So erfahren sie, dass der Link nicht mehr gilt
      if (what === "ws" && request.headers.get("upgrade") === "websocket") {
        const pair = new WebSocketPair();
        pair[1].accept();
        pair[1].close(4001, "Teilen beendet");
        return new Response(null, { status: 101, webSocket: pair[0] });
      }
      return json({ error: "Dieser Link ist nicht (mehr) gültig." }, 404);
    }
    const doc = share.doc;
    if (what === "ws") return this.accept(request, doc, "guest");
    if (what === "pdf") return this.blobResponse(`pdf/${doc}`);
    // Für Browser, deren Netz keinen WebSocket durchlässt: dasselbe Nachholen wie beim Verbinden, per Abfrage
    if (what === "changes") return json(this.missed(doc, new URL(request.url).searchParams));
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

  // ---------- Fragen an Claude ----------
  // Eine Frage durchläuft open → claimed (der Helfer am Mac arbeitet daran) → answered oder failed. Gibt der Helfer
  // sie zurück (release, etwa am Nutzungslimit) oder läuft seine Frist ab, ist sie wieder open. Die Markierung löschen
  // (oder das ganze Dokument) entfernt sie in jedem Zustand. Ihre beiden Bilder gibt es nur, bis sie fertig ist.
  // Apps bekommen nach jeder Änderung den Hinweis {type: "asks", v} (nur Apps, nie Gäste) und holen die Liste selbst.
  // Der Helfer bekommt bei jeder neuen Frage {type: "ask"} und holt dann /api/asks/open.

  /// Version der Fragen über alle Dokumente: steigt mit jeder Änderung
  nextAsksV() {
    return this.sql
      .exec("INSERT INTO counter (k, v) VALUES ('asks', 1) ON CONFLICT(k) DO UPDATE SET v = v + 1 RETURNING v")
      .one().v;
  }

  askRow(askId) {
    return this.sql.exec("SELECT * FROM asks WHERE id = ?", askId).toArray()[0];
  }

  /// Gelöschte Fragen merkt sich der Server 30 Tage (asks_gone): Lädt ein Gerät eine davon noch einmal hoch, weil die
  /// Antwort auf sein erstes Hochladen verloren ging, kommt sie nicht wieder
  askGone(askId) {
    return this.sql.exec("SELECT 1 FROM asks_gone WHERE id = ?", askId).toArray().length > 0;
  }

  /// Alle Fragen eines Dokuments mit der Version, bis zu der die Liste vollständig ist. Nur Antworten mit der ganzen
  /// Liste dürfen der App ihre bekannte Version setzen, sonst verpasst sie eine Änderung dazwischen
  docAsks(doc) {
    const v = this.sql.exec("SELECT v FROM counter WHERE k = 'asks'").toArray()[0]?.v || 0;
    return { v, asks: this.sql.exec("SELECT * FROM asks WHERE doc = ?", doc).toArray().map(publicAsk) };
  }

  asksChanged(doc, v) {
    this.broadcast(doc, { type: "asks", v }, `app:${doc}`);
  }

  /// Neue Frage in einem einzigen multipart-Aufruf: meta (JSON: anchor, pv, effort, created, from), question (PNG,
  /// nur die Frage) und page (JPEG oder PNG: die ganze Seite, die Frage darauf hervorgehoben). Bilder und Zeile
  /// landen zusammen oder gar nicht. Lädt die App dieselbe Frage noch einmal hoch (Antwort verloren),
  /// ändert sich nichts
  async createAsk(request, doc, askId) {
    if (!UUID_RE.test(askId)) return fail("Ungültige Kennung", "bad-id", 400);
    if (this.askRow(askId) || this.askGone(askId)) return json(this.docAsks(doc));
    // Billige Prüfungen, bevor die Bilder gelesen werden (danach noch einmal: dazwischen kann anderes laufen)
    const early = this.askRefused(doc, null);
    if (early) return early;
    let form;
    try {
      form = await request.formData();
    } catch {
      return fail("multipart erwartet", "bad-body", 400);
    }
    // Ein Teil ohne Dateinamen käme als Text an, die Bytes des Bildes wären verdorben
    const q = form.get("question"), p = form.get("page"), m = form.get("meta");
    if (!q || !p || typeof q === "string" || typeof p === "string") return fail("Bilder fehlen", "bad-body", 400);
    if (q.size > MAX_QUESTION_BYTES || p.size > MAX_PAGE_BYTES) return fail("Bild zu groß", "too-large", 413);
    let meta = null;
    try {
      meta = JSON.parse(typeof m === "string" ? m : m ? await m.text() : "null");
    } catch {}
    const qb = await q.arrayBuffer(), pb = await p.arrayBuffer();
    // Ab hier ohne Unterbrechung: Dazwischen läuft nichts anderes
    if (this.askRow(askId) || this.askGone(askId)) return json(this.docAsks(doc));
    const anchor = cleanAnchor(meta?.anchor), qt = imageType(qb), pt = imageType(pb);
    if (!anchor || !qt || !pt) return fail("Stelle oder Bild ungültig", "bad-body", 400);
    const refused = this.askRefused(doc, meta);
    if (refused) return refused;
    const now = Date.now() / 1000;
    let v;
    this.ctx.storage.transactionSync(() => {
      this.writeBlob(`ask/${askId}/question`, qb, qt);
      this.writeBlob(`ask/${askId}/page`, pb, pt);
      v = this.nextAsksV();
      this.sql.exec(
        "INSERT INTO asks (id, doc, status, anchor, pv, effort, created, updated, info, v) " +
          "VALUES (?, ?, 'open', ?, ?, ?, ?, ?, ?, ?)",
        askId, doc, JSON.stringify(anchor), Math.max(0, Math.trunc(Number(meta.pv) || 0)),
        EFFORTS.includes(meta.effort) ? meta.effort : EFFORTS[0], Number(meta.created) || now, now,
        JSON.stringify({ from: String(meta.from || "").slice(0, 40) }), v,
      );
    });
    this.asksChanged(doc, v);
    this.broadcast(null, { type: "ask" }, "helper");
    return json(this.docAsks(doc));
  }

  /// Warum eine neue Frage nicht angenommen wird, sonst null. Mit `meta` auch: gestellt auf einem älteren Seitenstand
  /// (ein anderes Gerät hat inzwischen Seiten gelöscht oder eingefügt), dann stimmt ihre Stelle nicht mehr
  askRefused(doc, meta) {
    const d = this.sql.exec("SELECT meta FROM docs WHERE id = ?", doc).toArray()[0];
    const docMeta = d ? JSON.parse(d.meta) : null;
    if (!docMeta || docMeta.deleted) return fail("Dokument nicht auf dem Server", "no-doc", 404);
    if (meta && Math.trunc(Number(meta.pv) || 0) < (Number(docMeta.pagesVersion) || 0)) {
      return fail("Die Seiten haben sich inzwischen geändert", "stale-pages", 409);
    }
    if (this.sql.exec("SELECT COUNT(*) AS n FROM asks WHERE status IN ('open', 'claimed')").one().n >= MAX_OPEN_ASKS) {
      return fail("Zu viele offene Fragen", "too-many", 429);
    }
    return null;
  }

  /// Markierung löschen, auf allen Geräten
  deleteAsk(doc, askId) {
    const row = this.askRow(askId);
    if (row && row.doc === doc) this.dropAsks(doc, [row]);
    // Noch nicht angekommen (ihr Hochladen ist vielleicht noch unterwegs): Kommt es später, legt es sie nicht mehr an
    else if (!row && UUID_RE.test(askId)) {
      this.sql.exec("INSERT OR REPLACE INTO asks_gone (id, t) VALUES (?, ?)", askId, Date.now() / 1000);
    }
    return this.docAsks(doc);
  }

  /// Das Dokument wurde gelöscht: seine Fragen mit
  deleteDocAsks(doc) {
    this.dropAsks(doc, this.sql.exec("SELECT id, status FROM asks WHERE doc = ?", doc).toArray());
  }

  /// Entfernt Fragen eines Dokuments samt ihren Bildern. Arbeitet der Helfer gerade an einer,
  /// erfährt er es und bricht ab
  dropAsks(doc, rows) {
    if (!rows.length) return;
    let v;
    const now = Date.now() / 1000;
    this.ctx.storage.transactionSync(() => {
      for (const r of rows) {
        if (r.status === "open" || r.status === "claimed") this.deleteAskImages(r.id);
        this.sql.exec("DELETE FROM asks WHERE id = ?", r.id);
        this.sql.exec("INSERT OR REPLACE INTO asks_gone (id, t) VALUES (?, ?)", r.id, now);
      }
      // Nach 30 Tagen vergessen: So lange wartet keine verlorene Antwort (liest nur die abgelaufenen, über den Index)
      this.sql.exec("DELETE FROM asks_gone WHERE t < ?", now - 30 * 86400);
      v = this.nextAsksV();
    });
    this.asksChanged(doc, v);
    for (const r of rows) if (r.status === "claimed") this.broadcast(null, { type: "cancel", id: r.id }, "helper");
  }

  deleteAskImages(askId) {
    this.deleteBlob(`ask/${askId}/question`);
    this.deleteBlob(`ask/${askId}/page`);
  }

  /// Nach dem Löschen oder Einfügen von Seiten: body {pv, anchors: {askId: anchor | null}}, null heißt, die Seite der
  /// Frage ist weg (die Frage mit). Wie bei pagesVersion nie zurück zu einer älteren Seitenordnung
  moveAsks(doc, body) {
    const pv = Math.max(0, Math.trunc(Number(body?.pv) || 0));
    const entries = body?.anchors && typeof body.anchors === "object" ? Object.entries(body.anchors) : [];
    const gone = [];
    let v = 0;
    this.ctx.storage.transactionSync(() => {
      for (const [askId, a] of entries) {
        const row = this.sql.exec("SELECT id, status, pv FROM asks WHERE id = ? AND doc = ?", askId, doc).toArray()[0];
        // Seite −1: Die Seite der Frage wurde gelöscht, Rückgängig ist noch möglich (die Apps zeigen sie nicht)
        const anchor = a === null ? null : cleanAnchor(a, true);
        if (!row || row.pv > pv || (a !== null && !anchor)) continue;
        if (!anchor) {
          gone.push(row);
          continue;
        }
        v = v || this.nextAsksV();
        this.sql.exec(
          "UPDATE asks SET anchor = ?, pv = ?, updated = ?, v = ? WHERE id = ?",
          JSON.stringify(anchor), pv, Date.now() / 1000, v, askId,
        );
      }
    });
    if (v) this.asksChanged(doc, v);
    this.dropAsks(doc, gone);
    return this.docAsks(doc);
  }

  /// Für den Helfer: offene Fragen und übernommene, deren Frist abgelaufen ist, die älteste zuerst. Liest nur über den
  /// Index asks_status, also nie die beantworteten (die sich ansammeln). `next`: in wie vielen Sekunden die nächste
  /// zurückgestellte oder übernommene Frage fällig wird (null, wenn keine)
  openAsks() {
    const now = Date.now() / 1000;
    const rows = this.sql
      .exec("SELECT id, doc, status, effort, created, lease FROM asks WHERE status IN ('open', 'claimed')")
      .toArray();
    const later = rows.filter((r) => r.lease > now).map((r) => r.lease - now);
    return {
      asks: rows
        .filter((r) => r.lease <= now)
        .sort((a, b) => a.created - b.created)
        .map((r) => ({ id: r.id, doc: r.doc, effort: r.effort, created: r.created, retry: r.status === "claimed" })),
      next: later.length ? Math.ceil(Math.min(...later)) : null,
    };
  }

  /// Der Helfer übernimmt eine Frage: body {lease} in Sekunden (60 bis 3600). Mit {claim} seines laufenden Auftrags
  /// verlängert er stattdessen die Frist. Die Antwort enthält alles zum Beantworten außer den Bildern
  /// (die holt er einzeln)
  async claimAsk(askId, request) {
    const body = await bodyJSON(request);
    const row = this.askRow(askId);
    if (!row) return fail("Diese Frage gibt es nicht (mehr)", "gone", 404);
    const now = Date.now() / 1000;
    const lease = Math.min(Math.max(Number(body.lease) || ASK_LEASE, 60), 3600);
    if (row.status === "claimed" && body.claim && body.claim === row.claim) {
      this.sql.exec("UPDATE asks SET lease = ? WHERE id = ?", now + lease, askId);
      return json({ id: askId, claim: row.claim, leaseUntil: now + lease });
    }
    const expired = row.status === "claimed" && row.lease <= now;
    if (row.status !== "open" && !expired) {
      return json({ error: "Schon vergeben", code: "taken", status: row.status }, 409);
    }
    // Bricht der Helfer an einer Frage immer wieder ab (etwa weil er an ihr abstürzt), nicht endlos weiter versuchen
    const retries = row.retries + (expired ? 1 : 0);
    if (retries >= MAX_ASK_RETRIES) {
      this.finishAsk(row, "failed", { note: "Der Helfer am Mac hat mehrmals nicht geantwortet." });
      return fail("Aufgegeben", "failed", 409);
    }
    const claim = crypto.randomUUID();
    let v;
    this.ctx.storage.transactionSync(() => {
      v = this.nextAsksV();
      this.sql.exec(
        "UPDATE asks SET status = 'claimed', lease = ?, claim = ?, retries = ?, note = NULL, updated = ?, v = ? " +
          "WHERE id = ?",
        now + lease, claim, retries, now, v, askId,
      );
    });
    this.asksChanged(row.doc, v);
    const d = this.sql.exec("SELECT meta FROM docs WHERE id = ?", row.doc).toArray()[0];
    const meta = d ? JSON.parse(d.meta) : {};
    const image = (name) =>
      this.sql.exec("SELECT size, type FROM blobmeta WHERE key = ?", `ask/${askId}/${name}`).toArray()[0] || null;
    return json({
      id: askId, claim, leaseUntil: now + lease, anchor: JSON.parse(row.anchor), pv: row.pv, effort: row.effort,
      created: row.created, from: JSON.parse(row.info || "{}").from || null,
      doc: {
        id: row.doc, title: meta.title || "", kind: meta.kind || "notebook", pageCount: meta.pageCount || 0,
        pagesVersion: meta.pagesVersion || 0, pdfVersion: meta.pdfVersion || 0,
        hasPDF: this.sql.exec("SELECT 1 FROM blobmeta WHERE key = ?", `pdf/${row.doc}`).toArray().length > 0,
      },
      images: { question: image("question"), page: image("page") },
    });
  }

  /// Der Helfer meldet sich zurück, mit dem claim seines Auftrags. JSON {claim, markdown}: beantwortet;
  /// {claim, error}: gescheitert (die App zeigt den Text); {claim, release: true, note?, retryAfter?, count?}: zurück
  /// in die Warteschlange, frühestens nach retryAfter Sekunden (etwa am Nutzungslimit; die App zeigt note). Statt JSON geht
  /// auch text/markdown mit ?claim=…. Wiederholt er eine Antwort (Antwort verloren), ändert sich nichts
  async answerAsk(askId, request, url) {
    const raw = (request.headers.get("content-type") || "").startsWith("text/markdown");
    const body = raw
      ? { claim: url.searchParams.get("claim"), markdown: await request.text() }
      : await bodyJSON(request);
    const row = this.askRow(askId);
    if (!row) return fail("Diese Frage gibt es nicht (mehr)", "gone", 404);
    if (!body.claim || body.claim !== row.claim) {
      return json({ error: "Nicht dein Auftrag", code: "not-yours", status: row.status }, 409);
    }
    if (row.status === "answered" || row.status === "failed") return json({ ok: true, v: row.v });
    if (body.release) {
      const now = Date.now() / 1000;
      const retryAfter = Math.min(Math.max(Number(body.retryAfter) || 0, 0), 86400);
      // Gibt ein Helfer dieselbe Frage immer wieder gleich zurück (etwa nach einem Fehler am Mac), zählt das wie eine
      // abgelaufene Frist: Nach MAX_ASK_RETRIES gibt der Server auf, statt sie endlos kreisen zu lassen (jede Runde
      // schreibt Zeilen). Nicht bei langen Pausen und nicht bei count: false (der Helfer sagt, es liegt nicht an
      // dieser Frage: abgemeldet, Nutzungslimit, Neustart, oder er zählt selbst)
      const retries = row.retries + (body.count !== false && retryAfter < 600 ? 1 : 0);
      let v;
      this.ctx.storage.transactionSync(() => {
        v = this.nextAsksV();
        this.sql.exec(
          "UPDATE asks SET status = 'open', claim = NULL, lease = ?, retries = ?, note = ?, updated = ?, v = ? " +
            "WHERE id = ?",
          now + retryAfter, retries,
          typeof body.note === "string" && body.note ? body.note.slice(0, 300) : null, now, v, askId,
        );
      });
      this.asksChanged(row.doc, v);
      return json({ ok: true, v });
    }
    if (typeof body.markdown === "string" && body.markdown.trim()) {
      if (body.markdown.length > MAX_ANSWER_CHARS) return fail("Antwort zu lang", "too-large", 413);
      return json({ ok: true, v: this.finishAsk(row, "answered", { answer: body.markdown }) });
    }
    if (typeof body.error === "string") {
      return json({ ok: true, v: this.finishAsk(row, "failed", { note: body.error.slice(0, 2000) || "Fehler" }) });
    }
    return fail("markdown, error oder release fehlt", "bad-body", 400);
  }

  finishAsk(row, status, { answer = null, note = null } = {}) {
    let v;
    this.ctx.storage.transactionSync(() => {
      v = this.nextAsksV();
      this.sql.exec(
        "UPDATE asks SET status = ?, answer = ?, note = ?, lease = 0, updated = ?, v = ? WHERE id = ?",
        status, answer, note, Date.now() / 1000, v, row.id,
      );
      this.deleteAskImages(row.id);
    });
    this.asksChanged(row.doc, v);
    return v;
  }

  /// Der Helfer am Mac wartet über diesen WebSocket auf neue Fragen. Das Objekt schläft dabei (Hibernation), und sein
  /// "ping" beantwortet der Server, ohne aufzuwachen
  acceptHelper(request) {
    if (request.headers.get("upgrade") !== "websocket") return json({ error: "WebSocket erwartet" }, 426);
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1], ["helper"]);
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  // ---------- Briefkasten ----------

  /// Ein PDF oder Markdown in den Eingang: wird ein neues Dokument, das auf allen Geräten erscheint
  async inbox(request, url) {
    const bytes = await request.arrayBuffer();
    const isPDF = String.fromCharCode(...new Uint8Array(bytes.slice(0, 5))) === "%PDF-";
    if (!isPDF && !markdownRequested(request, url)) {
      throw new Error("Das ist kein PDF. Markdown bitte mit ?type=md (oder Content-Type: text/markdown) schicken");
    }
    const id = crypto.randomUUID().toUpperCase();
    const now = Date.now() / 1000;
    // Was Claude oder ChatGPT schicken, landet im Ordner „temp“ (die App löscht es dort nach 2 Wochen)
    const meta = { id, title: "", kind: "pdf", created: now, modified: now, pageCount: 0, layoutVersion: 2, folder: "temp" };
    if (isPDF) {
      meta.title = clipTitle(url.searchParams.get("title") || "Aus dem Eingang");
      this.putBlob(`pdf/${id}`, bytes, "application/pdf");
      this.putMeta(id, meta);
      return { id, title: meta.title };
    }
    // Markdown: ein PDF-Dokument, das noch kein PDF hat. Das erste Gerät mit einer App, die Markdown kennt, setzt es
    // und lädt das PDF hoch (putFirstPDF); ältere Apps übergehen PDF-Dokumente ohne PDF, sehen es also erst danach
    const text = markdownText(bytes);
    meta.title = clipTitle(url.searchParams.get("title") || markdownTitle(text) || "Aus dem Eingang");
    meta.source = "md";
    const utf8 = new TextEncoder().encode(text);
    this.ctx.storage.transactionSync(() => {
      this.writeBlob(`md/${id}`, utf8.buffer.slice(utf8.byteOffset, utf8.byteOffset + utf8.byteLength),
        "text/markdown; charset=utf-8");
      this.putMeta(id, meta);
    });
    return { id, title: meta.title, source: "md" };
  }

  /// Das PDF eines Markdown aus dem Eingang, gesetzt von einem Gerät. Setzen es mehrere zugleich, gilt das erste:
  /// Alle laden dann genau dieses, sonst lägen die Striche auf jedem Gerät auf einem etwas anders gesetzten PDF.
  /// Erst jetzt erscheint es auf den Geräten, also gilt es ab jetzt als geändert (die 2 Wochen im Ordner „temp“
  /// zählen ab hier, und in der Übersicht steht es oben)
  putFirstPDF(id, bytes) {
    if (String.fromCharCode(...new Uint8Array(bytes.slice(0, 5))) !== "%PDF-") throw new Error("Das ist kein PDF");
    const row = this.sql.exec("SELECT meta, modified FROM docs WHERE id = ?", id).toArray()[0];
    const meta = row ? JSON.parse(row.meta) : null;
    if (!meta || meta.deleted) return { ok: false, gone: true };
    if (this.sql.exec("SELECT 1 FROM blobmeta WHERE key = ?", `pdf/${id}`).toArray().length) return { ok: false, exists: true };
    meta.modified = Math.max(Number(row.modified) || 0, Date.now() / 1000);
    this.ctx.storage.transactionSync(() => {
      this.writeBlob(`pdf/${id}`, bytes, "application/pdf");
      this.sql.exec("UPDATE docs SET meta = ?, modified = ?, seq = ? WHERE id = ?",
        JSON.stringify(meta), meta.modified, this.nextSeq(), id);
    });
    return { ok: true };
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
    this.ctx.storage.transactionSync(() => this.writeBlob(key, buffer, type));
  }

  /// Wie putBlob, aber ohne eigene Transaktion: So landen mehrere Dateien und ihre Zeile zusammen oder gar nicht
  writeBlob(key, buffer, type) {
    this.sql.exec("DELETE FROM blobs WHERE key = ?", key);
    for (let off = 0, part = 0; off < buffer.byteLength; off += CHUNK, part++) {
      this.sql.exec("INSERT INTO blobs (key, part, data) VALUES (?, ?, ?)", key, part, buffer.slice(off, off + CHUNK));
    }
    this.sql.exec(
      "INSERT OR REPLACE INTO blobmeta (key, size, type, created) VALUES (?, ?, ?, ?)",
      key, buffer.byteLength, type || "application/octet-stream", Date.now() / 1000,
    );
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

/// Name eines Dokuments aus dem Eingang: höchstens 200 Zeichen, ohne ein halbes Zeichenpaar am Ende (etwa von einem
/// Emoji). Das ergäbe JSON, das die Apps nicht lesen können, und damit hielte die ganze Bibliothek auf allen Geräten an
function clipTitle(s) {
  return s.slice(0, 200).replace(/[\uD800-\uDBFF]$/, "");
}

/// Markdown im Eingang: ausdrücklich mit ?type=md, oder als Text geschickt (Content-Type text/markdown oder text/plain)
function markdownRequested(request, url) {
  const type = (url.searchParams.get("type") || "").toLowerCase();
  if (type === "md" || type === "markdown") return true;
  const ct = (request.headers.get("content-type") || "").split(";")[0].trim().toLowerCase();
  return ct === "text/markdown" || ct === "text/x-markdown" || ct === "text/plain";
}

/// Der Text eines Markdown aus dem Eingang: UTF-8 (ein BOM fällt weg), nicht leer, nicht zu groß, keine Binärdatei
function markdownText(bytes) {
  if (bytes.byteLength > MAX_MARKDOWN_BYTES) throw new Error(`Markdown zu groß (höchstens ${MAX_MARKDOWN_BYTES / 1024} KB)`);
  let text;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch (e) {
    throw new Error("Markdown muss UTF-8 sein");
  }
  if (!text.trim()) throw new Error("Leere Datei");
  if (/[\u0000-\u0008\u000E-\u001F\u007F]/.test(text)) throw new Error("Das ist keine Textdatei");
  return text;
}

/// Name für Markdown ohne ?title: title im Vorspann (YAML zwischen --- am Anfang), sonst die erste Überschrift
/// (# bis ###) außerhalb von Codeblöcken, ohne Markdown-Zeichen
function markdownTitle(text) {
  const lines = text.split(/\r\n?|\n/);
  let start = 0;
  if (/^---[ \t]*$/.test(lines[0])) {
    // Nur echter Vorspann (er beginnt mit „schlüssel:“), nicht eine Trennlinie am Anfang
    const end = lines.findIndex((l, i) => i > 0 && /^(---|\.\.\.)[ \t]*$/.test(l));
    const first = end > 0 ? lines.slice(1, end).find((l) => l.trim()) : undefined;
    if (end > 0 && end < 200 && first && /^[\w-]+:/.test(first)) {
      for (const l of lines.slice(1, end)) {
        const m = /^title:[ \t]*(.*?)[ \t]*$/i.exec(l);
        const t = m && plainTitle(m[1].replace(/^(["'])(.*)\1$/, "$2"));
        if (t) return t;
      }
      start = end + 1;
    }
  }
  let fence = null;
  for (const line of lines.slice(start, start + 500)) {
    const f = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line);
    if (fence) {
      if (f && f[1][0] === fence[0] && f[1].length >= fence.length && !f[2].trim()) fence = null;
      continue;
    }
    if (f) {
      fence = f[1];
      continue;
    }
    const h = /^ {0,3}#{1,3}[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$/.exec(line);
    const t = h && plainTitle(h[1]);
    if (t) return t;
  }
  return "";
}

/// Überschrift als Name: Links werden zu ihrem Text, Hervorhebung, Code- und Formelzeichen fallen weg
function plainTitle(s) {
  return s
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/\*+|`+|\$+|\\[()[\]]/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

// Seitenänderungen (löschen, einfügen) tragen eine eigene Version: pagesVersion für Seitenzahl und
// Reihenfolge, pdfVersion für das PDF selbst. Beide gehen nie zurück.
function newerStructure(a, b) {
  return (Number(a.pagesVersion) || 0) > (Number(b.pagesVersion) || 0) || (Number(a.pdfVersion) || 0) > (Number(b.pdfVersion) || 0);
}

/// Änderungen für Browser in Nachrichten von höchstens etwa 500 KB
function inParts(changes, send) {
  let part = [], size = 0;
  for (const c of changes) {
    const n = (c.data ? c.data.length : 0) + c.id.length + 40;
    if (size + n > 500000 && part.length) {
      send(part);
      part = [];
      size = 0;
    }
    part.push(c);
    size += n;
  }
  if (part.length) send(part);
}

/// Body als JSON (leer: {})
async function bodyJSON(request) {
  const text = await request.text();
  const body = text ? JSON.parse(text) : {};
  return body && typeof body === "object" ? body : {};
}

/// PNG oder JPEG, an den ersten Bytes erkannt (sonst null)
function imageType(buffer) {
  const b = new Uint8Array(buffer.slice(0, 4));
  if (b.length === 4 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return "image/png";
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "image/jpeg";
  return null;
}

/// Stelle einer Frage: Seite (ab 0) und Rechteck auf dieser Seite, in Seiteneinheiten (Breite 768, Ursprung oben links).
/// `detached`: auch Seite −1 (nur beim Verschieben: Seite gelöscht, Rückgängig noch möglich)
function cleanAnchor(a, detached = false) {
  if (!a || typeof a !== "object") return null;
  const page = Number(a.page), [x, y, w, h] = [a.x, a.y, a.w, a.h].map(Number);
  if (!Number.isInteger(page) || page < (detached ? -1 : 0) || page > 100000) return null;
  if (![x, y, w, h].every((n) => Number.isFinite(n) && Math.abs(n) < 1e6) || w < 0 || h < 0) return null;
  return { page, x, y, w, h };
}

/// Was die Apps von einer Frage sehen (ohne den claim des Helfers)
function publicAsk(r) {
  return {
    id: r.id, doc: r.doc, status: r.status, anchor: JSON.parse(r.anchor), pv: r.pv, effort: r.effort,
    created: r.created, updated: r.updated, answer: r.answer, note: r.note,
    from: JSON.parse(r.info || "{}").from || null, v: r.v,
  };
}

/// Übernimmt in `target` die Seitenangaben aus `other`, wo sie neuer sind
function takeStructure(target, other) {
  if ((Number(other.pagesVersion) || 0) > (Number(target.pagesVersion) || 0)) {
    target.pagesVersion = Number(other.pagesVersion);
    target.pageCount = other.pageCount;
  }
  if ((Number(other.pdfVersion) || 0) > (Number(target.pdfVersion) || 0)) target.pdfVersion = Number(other.pdfVersion);
}
