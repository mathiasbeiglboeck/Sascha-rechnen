// Notizbuch als Connector für Claude (MCP, „Streamable HTTP“ ohne Sitzungen): Mathias trägt die Adresse
// https://notizbuch…workers.dev/mcp/<Connector-Schlüssel> einmal in claude.ai unter Connectors ein, dann kann jeder Claude
// (Chats, Cloud-Threads aller Projekte, Claude Code am Mac) ans Notizbuch schicken, ohne Umgebungsvariablen.
//
// Der Connector-Schlüssel steht im Pfad (claude.ai kann für eigene Connectors keinen festen Header mitschicken) und ist
// aus SECRET abgeleitet (siehe mcpKey), so muss niemand ein zweites Geheimnis eintragen. Er darf nur, was diese Werkzeuge
// können: in den Eingang schicken, den Ausgang „claude“ lesen und aufräumen, Lernwörter ablegen und lesen. An Sync,
// Bibliothek, Striche und Fragen kommt er nicht. Zum Sperren eine Variable MCP_VERSION setzen (andere Zeichenkette =
// neuer Schlüssel, der alte gilt dann nicht mehr).
//
// Jede Werkzeug-Ausführung ist eine Anfrage an das Durable Object, wie ein curl-Aufruf aus BRIEFKASTEN.md.

const PROTOCOLS = ["2025-06-18", "2025-03-26", "2024-11-05"];
const SERVER_INFO = { name: "notizbuch", title: "Notizbuch", version: "1.0.0" };
// Was ein Werkzeug höchstens zurückgibt bzw. annimmt (ein Bild oder PDF aus dem Ausgang; ein PDF in den Eingang)
const MAX_OUT_BYTES = 6 * 1024 * 1024;
const MAX_PDF_BYTES = 30 * 1024 * 1024;
// Hochlade-Links gelten so lange (Sekunden)
const UPLOAD_TTL = 3600;
const MAX_LOG = 150;
const MAX_LERN = 500;

const INSTRUCTIONS = `Notizbuch ist Mathias' Notiz-App auf iPad und iPhone (er schreibt dort mit dem Stift).
- Notizen, Erklärungen, Antworten mit Formeln: notizbuch_markdown_senden (Markdown mit $…$ und $$…$$). Das ist der
  Normalfall, ein PDF muss dafür nicht erst gebaut werden.
- Ein fertiges PDF: notizbuch_pdf_senden mit pdf_url (öffentlich erreichbar) oder pdf_base64 (nur kleine Dateien). Liegt
  das PDF als Datei bei dir und hast du eine Shell, hol mit notizbuch_hochlade_link eine Adresse und lade es mit curl hoch.
- Sagt Mathias „schau in den Ausgang“ oder „ich hab dir eine Seite geschickt“: notizbuch_ausgang_liste, dann die neueste
  Datei mit notizbuch_ausgang_holen (das PNG zeigt seine Handschrift), danach notizbuch_ausgang_loeschen.
- Lernwörter für seinen Sohn Sascha (8, Volksschule Wien): notizbuch_lernwoerter_ablegen, Stand mit notizbuch_lernstand.
Was im Notizbuch landet, sieht Mathias innerhalb von etwa 20 Sekunden in der Übersicht (Ordner „temp“).`;

const TOOLS = [
  {
    name: "notizbuch_markdown_senden",
    title: "Markdown ans Notizbuch schicken",
    description:
      "Schickt Markdown (UTF-8, höchstens 512 KB) in Mathias' Notizbuch-App. Die App setzt es einmal auf A4-Seiten, " +
      "Formeln mit $…$, $$…$$, \\(…\\), \\[…\\]; Text, Listen, Tabellen, Code und Links ja, HTML und Bilder nein. " +
      "Danach schreibt er mit dem Stift darauf. Ohne title heißt das Dokument wie die erste Überschrift.",
    inputSchema: {
      type: "object",
      properties: {
        markdown: { type: "string", description: "Der Markdown-Text" },
        title: { type: "string", description: "Name des Dokuments (optional)" },
      },
      required: ["markdown"],
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  },
  {
    name: "notizbuch_pdf_senden",
    title: "PDF ans Notizbuch schicken",
    description:
      "Schickt ein PDF als neues Dokument in Mathias' Notizbuch-App. Entweder pdf_url (eine öffentlich erreichbare " +
      "Adresse, der Server lädt sie, höchstens 30 MB) oder pdf_base64 (der Inhalt base64-kodiert, nur für kleine Dateien). " +
      "Für eine größere Datei bei dir: notizbuch_hochlade_link.",
    inputSchema: {
      type: "object",
      properties: {
        title: { type: "string", description: "Name des Dokuments, etwa „Übungsblatt 3“" },
        pdf_url: { type: "string", description: "https-Adresse des PDFs" },
        pdf_base64: { type: "string", description: "Das PDF base64-kodiert" },
      },
      required: ["title"],
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
  },
  {
    name: "notizbuch_hochlade_link",
    title: "Hochlade-Adresse für eine Datei",
    description:
      "Gibt eine Adresse (1 Stunde gültig) samt curl-Befehl zurück, mit der du eine PDF- oder Markdown-Datei aus deiner " +
      "Shell direkt in den Eingang des Notizbuchs lädst. Nur nötig, wenn die Datei zu groß für pdf_base64 ist. Braucht " +
      "Netzzugang zu *.workers.dev.",
    inputSchema: { type: "object", properties: {} },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  },
  {
    name: "notizbuch_ausgang_liste",
    title: "Ausgang ansehen",
    description:
      "Listet, was Mathias aus der App an Claude geschickt hat (Teilen → „Seite an Claude senden“), neueste zuerst. " +
      "Eine Seite kommt als „<Titel> – Seite N.pdf“ und „.png“, ein ganzes Dokument als PDF.",
    inputSchema: { type: "object", properties: {} },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "notizbuch_ausgang_holen",
    title: "Datei aus dem Ausgang holen",
    description:
      "Holt eine Datei aus dem Ausgang (Name genau wie in notizbuch_ausgang_liste). Ein PNG kommt als Bild (zum Lesen " +
      "der Handschrift), ein PDF als eingebettete Datei. Höchstens 6 MB.",
    inputSchema: {
      type: "object",
      properties: { name: { type: "string", description: "Dateiname aus der Liste" } },
      required: ["name"],
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "notizbuch_ausgang_loeschen",
    title: "Datei aus dem Ausgang löschen",
    description: "Löscht eine abgeholte Datei aus dem Ausgang (aufräumen, wenn du sie gelesen hast).",
    inputSchema: {
      type: "object",
      properties: { name: { type: "string", description: "Dateiname aus der Liste" } },
      required: ["name"],
    },
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "notizbuch_lernwoerter_ablegen",
    title: "Lernwörter für Sascha ablegen",
    description:
      "Legt Lernwörter für Sascha (8) ab, die er in der App übt (die App spricht das Wort vor, er schreibt es). Jedes " +
      "Wort genau richtig geschrieben (Hauptwörter groß), mit kurzem kindgerechtem Satz, in dem es genau so vorkommt " +
      "(bei das/dass, Meer/mehr muss der Satz zeigen, welches gemeint ist). Ein bekanntes Wort behält seinen Lernstand. " +
      "remove nimmt Wörter heraus. Höchstens 500 Wörter.",
    inputSchema: {
      type: "object",
      properties: {
        add: {
          type: "array",
          items: {
            type: "object",
            properties: { wort: { type: "string" }, satz: { type: "string" } },
            required: ["wort"],
          },
        },
        remove: { type: "array", items: { type: "string" } },
      },
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "notizbuch_lernstand",
    title: "Lernstand der Lernwörter",
    description:
      "Saschas Lernwörter und seine letzten Versuche. ergebnis: richtig (gleich beim ersten Mal), zweiter (nach dem " +
      "Hinweis), falsch; gelesen = was der Mac aus seiner Schrift gelesen hat; t = Sekunden seit 1970.",
    inputSchema: { type: "object", properties: {} },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
];

/// Der Connector-Schlüssel: HMAC-SHA256(SECRET, "mcp-connector[:MCP_VERSION]"), base64url, 32 Zeichen.
/// claude-fragen/connector-link.sh rechnet am Mac dasselbe aus
export async function mcpKey(env) {
  return hmac(env.SECRET, "mcp-connector" + (env.MCP_VERSION ? `:${env.MCP_VERSION}` : ""), 32);
}

async function hmac(secret, text, len) {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(text)));
  return b64url(mac).slice(0, len);
}

function b64url(bytes) {
  return b64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/// base64 einer Seite (bis einige MB) muss in die 10 ms CPU des Gratis-Tarifs passen: eingebaut, wo es das gibt,
/// sonst über apply in Stücken (ein Spread kostete etwa 35 ms je MB)
function b64(bytes) {
  if (typeof bytes.toBase64 === "function") return bytes.toBase64();
  const parts = [];
  for (let i = 0; i < bytes.length; i += 0x8000) parts.push(String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000)));
  return btoa(parts.join(""));
}

function fromB64(s) {
  if (typeof Uint8Array.fromBase64 === "function") return Uint8Array.fromBase64(s);
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function sameText(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

const notFound = () => new Response("Nicht gefunden\n", { status: 404, headers: { "content-type": "text/plain; charset=utf-8" } });

/// /mcp/<Schlüssel>: der Connector. Ein falscher Schlüssel bekommt 404 (keine 401: die ließe claude.ai eine
/// OAuth-Anmeldung suchen, die es hier nicht gibt)
export async function handleMCP(request, env, store, key, origin) {
  if (!env.SECRET || !sameText(key, await mcpKey(env))) return notFound();
  if (request.method !== "POST") {
    return new Response("Nur POST (MCP Streamable HTTP ohne Ereignisstrom)\n", { status: 405, headers: { allow: "POST" } });
  }
  let msg;
  try {
    msg = await request.json();
  } catch {
    return rpcJSON({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Kein gültiges JSON" } }, 400);
  }
  const ctx = { env, store, origin };
  if (Array.isArray(msg)) {
    const out = (await Promise.all(msg.map((m) => handleMessage(m, ctx)))).filter(Boolean);
    return out.length ? rpcJSON(out) : new Response(null, { status: 202 });
  }
  const out = await handleMessage(msg, ctx);
  return out ? rpcJSON(out) : new Response(null, { status: 202 });
}

const rpcJSON = (data, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });

async function handleMessage(msg, ctx) {
  if (!msg || typeof msg !== "object" || msg.jsonrpc !== "2.0" || typeof msg.method !== "string") {
    // Antworten des Clients (auf Anfragen, die dieser Server nie stellt) oder Unsinn
    return msg && "id" in msg && msg.method === undefined ? null
      : { jsonrpc: "2.0", id: msg?.id ?? null, error: { code: -32600, message: "Ungültige Anfrage" } };
  }
  const isNotification = !("id" in msg);
  const reply = (result) => (isNotification ? null : { jsonrpc: "2.0", id: msg.id, result });
  const error = (code, message) => (isNotification ? null : { jsonrpc: "2.0", id: msg.id, error: { code, message } });
  switch (msg.method) {
    case "initialize": {
      const asked = msg.params?.protocolVersion;
      return reply({
        protocolVersion: PROTOCOLS.includes(asked) ? asked : PROTOCOLS[0],
        capabilities: { tools: { listChanged: false } },
        serverInfo: SERVER_INFO,
        instructions: INSTRUCTIONS,
      });
    }
    case "ping":
      return reply({});
    case "tools/list":
      return reply({ tools: TOOLS });
    case "tools/call": {
      const name = msg.params?.name;
      const args = msg.params?.arguments && typeof msg.params.arguments === "object" ? msg.params.arguments : {};
      if (!TOOLS.some((t) => t.name === name)) return error(-32602, `Unbekanntes Werkzeug: ${name}`);
      try {
        return reply(await callTool(name, args, ctx));
      } catch (e) {
        // Fehler beim Ausführen sieht das Modell (isError), damit es sich korrigieren kann
        return reply({ content: [{ type: "text", text: String(e?.message || e) }], isError: true });
      }
    }
    default:
      if (msg.method.startsWith("notifications/")) return null;
      return error(-32601, `Unbekannte Methode: ${msg.method}`);
  }
}

const text = (t) => ({ content: [{ type: "text", text: typeof t === "string" ? t : JSON.stringify(t, null, 1) }] });

/// Eine Anfrage an das Durable Object, wie sie ein curl-Aufruf aus BRIEFKASTEN.md stellen würde
async function api(store, method, path, body, contentType) {
  const headers = contentType ? { "content-type": contentType } : {};
  const res = await store.fetch(new Request(`https://notizbuch.intern${path}`, { method, headers, body }));
  const ct = res.headers.get("content-type") || "";
  if (ct.includes("application/json")) {
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || `Fehler ${res.status}`);
    return { data, type: ct };
  }
  if (!res.ok) throw new Error(`Fehler ${res.status}`);
  return { bytes: new Uint8Array(await res.arrayBuffer()), type: ct };
}

const str = (v, what) => {
  if (typeof v !== "string" || !v.trim()) throw new Error(`${what} fehlt`);
  return v;
};
// "." und ".." machte new Request() zu /api/outbox/ (die Liste aller Ausgänge samt chatgpt)
const outName = (name) => {
  if (str(name, "name") === "." || name === "..") throw new Error("Diese Datei gibt es nicht");
  return `/api/outbox/claude/${encodeURIComponent(name)}`;
};

async function callTool(name, a, { env, store, origin }) {
  switch (name) {
    case "notizbuch_markdown_senden": {
      const q = new URLSearchParams({ type: "md" });
      if (typeof a.title === "string" && a.title.trim()) q.set("title", a.title.trim());
      const { data } = await api(store, "POST", `/api/inbox?${q}`, str(a.markdown, "markdown"), "text/markdown; charset=utf-8");
      return text(`Im Notizbuch angekommen: „${data.title}“. Mathias sieht es in etwa 20 Sekunden (Ordner „temp“).`);
    }
    case "notizbuch_pdf_senden": {
      let bytes;
      if (typeof a.pdf_base64 === "string" && a.pdf_base64.trim()) {
        const clean = a.pdf_base64.replace(/^data:[^,]*,/, "").replace(/\s+/g, "");
        try {
          bytes = fromB64(clean.replace(/-/g, "+").replace(/_/g, "/"));
        } catch {
          throw new Error("pdf_base64 ist kein gültiges base64");
        }
      } else if (typeof a.pdf_url === "string" && a.pdf_url.trim()) {
        let u;
        try {
          u = new URL(a.pdf_url.trim());
        } catch {
          throw new Error("pdf_url ist keine gültige Adresse");
        }
        if (u.protocol !== "https:" && u.protocol !== "http:") throw new Error("pdf_url muss mit https:// beginnen");
        const res = await fetch(u, { redirect: "follow" });
        if (!res.ok) throw new Error(`pdf_url antwortet mit ${res.status}`);
        if (Number(res.headers.get("content-length")) > MAX_PDF_BYTES) throw new Error("PDF zu groß (höchstens 30 MB)");
        bytes = new Uint8Array(await res.arrayBuffer());
      } else {
        throw new Error("pdf_url oder pdf_base64 angeben");
      }
      if (bytes.byteLength > MAX_PDF_BYTES) throw new Error("PDF zu groß (höchstens 30 MB)");
      if (String.fromCharCode(...bytes.subarray(0, 5)) !== "%PDF-") throw new Error("Das ist kein PDF");
      const q = new URLSearchParams({ title: str(a.title, "title").trim() });
      const { data } = await api(store, "POST", `/api/inbox?${q}`, bytes, "application/pdf");
      return text(`Im Notizbuch angekommen: „${data.title}“ (${Math.round(bytes.byteLength / 1024)} KB). Mathias sieht es in etwa 20 Sekunden.`);
    }
    case "notizbuch_hochlade_link": {
      const exp = Math.floor(Date.now() / 1000) + UPLOAD_TTL;
      const link = `${origin}/up/${exp}/${await uploadSig(env, exp)}`;
      return text(
        `Hochlade-Adresse (gültig bis ${new Date(exp * 1000).toISOString()}, für mehrere Dateien):\n${link}\n\n` +
        `PDF:      curl -sS -X POST "${link}?title=Übungsblatt%203" --data-binary @blatt.pdf\n` +
        `Markdown: curl -sS -X POST "${link}?type=md" -H "Content-Type: text/markdown; charset=utf-8" --data-binary @notizen.md\n\n` +
        "Die Adresse ist ein Zugang zum Eingang: nicht ins Repo, in Dateien oder in den Chat schreiben.",
      );
    }
    case "notizbuch_ausgang_liste": {
      const { data } = await api(store, "GET", "/api/outbox/claude");
      if (!data.files.length) return text("Der Ausgang ist leer.");
      return text(data.files.map((f) => ({
        name: f.name, size: f.size, type: f.type, created: new Date(f.created * 1000).toISOString(),
      })));
    }
    case "notizbuch_ausgang_holen": {
      const { bytes, data, type } = await api(store, "GET", outName(a.name));
      if (!bytes) return text(data);
      if (bytes.byteLength > MAX_OUT_BYTES) throw new Error("Datei zu groß für den Connector (höchstens 6 MB); das PNG der Seite nehmen");
      const mime = type.split(";")[0].trim() || "application/octet-stream";
      if (mime.startsWith("image/")) return { content: [{ type: "image", data: b64(bytes), mimeType: mime }] };
      if (mime.startsWith("text/") || mime === "application/json") {
        return text(new TextDecoder().decode(bytes));
      }
      return {
        content: [
          { type: "text", text: `${a.name} (${mime}, ${Math.round(bytes.byteLength / 1024)} KB)` },
          { type: "resource", resource: { uri: `notizbuch://ausgang/claude/${encodeURIComponent(a.name)}`, mimeType: mime, blob: b64(bytes) } },
        ],
      };
    }
    case "notizbuch_ausgang_loeschen": {
      await api(store, "DELETE", outName(a.name));
      return text(`Gelöscht: ${a.name}`);
    }
    case "notizbuch_lernwoerter_ablegen": {
      const body = { add: Array.isArray(a.add) ? a.add : [], remove: Array.isArray(a.remove) ? a.remove : [] };
      if (!body.add.length && !body.remove.length) throw new Error("add oder remove angeben");
      if (body.add.length > MAX_LERN || body.remove.length > MAX_LERN) throw new Error(`Höchstens ${MAX_LERN} Wörter auf einmal`);
      const { data } = await api(store, "POST", "/api/lernen/woerter", JSON.stringify(body), "application/json; charset=utf-8");
      return text({ abgelegt: data.added, entfernt: data.removed });
    }
    case "notizbuch_lernstand": {
      const { data } = await api(store, "GET", "/api/lernen");
      const words = data.words.filter((w) => !w.removed).map((w) => (w.satz ? { wort: w.wort, satz: w.satz } : { wort: w.wort }));
      const log = data.log.slice(-MAX_LOG).map(({ seq, id, ...e }) => e);
      return text({ woerter: words, versuche: log, versuche_gesamt: data.log.length });
    }
  }
  throw new Error(`Unbekanntes Werkzeug: ${name}`);
}

const uploadSig = (env, exp) => hmac(env.SECRET, `upload:${exp}` + (env.MCP_VERSION ? `:${env.MCP_VERSION}` : ""), 32);

/// /up/<Ablauf>/<Signatur>: Hochlade-Adresse aus notizbuch_hochlade_link, geht wie POST /api/inbox (gleiche Parameter)
export async function handleUpload(request, env, store, exp, sig) {
  const t = Number(exp);
  if (!env.SECRET || !Number.isInteger(t) || !sameText(sig, await uploadSig(env, exp))) return notFound();
  if (t < Date.now() / 1000) {
    return new Response(JSON.stringify({ error: "Hochlade-Adresse abgelaufen; mit notizbuch_hochlade_link eine neue holen" }),
      { status: 410, headers: { "content-type": "application/json" } });
  }
  if (request.method !== "POST") return new Response("Nur POST\n", { status: 405, headers: { allow: "POST" } });
  const url = new URL(request.url);
  const inner = new Request(`https://notizbuch.intern/api/inbox${url.search}`, {
    method: "POST", headers: { "content-type": request.headers.get("content-type") || "" }, body: await request.arrayBuffer(),
  });
  return store.fetch(inner);
}
