// Test der Schnittstelle für „Claude fragen“ gegen einen lokalen Server mit Wegwerf-Schlüssel, nie gegen den echten:
//   cd native/Notizbuch/server && npx wrangler dev --ip 127.0.0.1 --port 8791 --var SECRET:testkey --persist-to <leerer Ordner>
//   BASE=http://127.0.0.1:8791 KEY=testkey node test/asks.mjs
// Die Fristen (Abschnitt „lease expiry“) brauchen eine kürzeste Frist von 1 s statt 60 s: eine Kopie von src/index.js mit
//   sed -i.bak 's/ASK_LEASE, 60), 3600/ASK_LEASE, 1), 3600/' src/index.js
// und SHORT_LEASE=1. Ohne SHORT_LEASE wird dieser Abschnitt übersprungen.
const BASE = process.env.BASE || "http://127.0.0.1:8791";
const KEY = process.env.KEY || "testkey";
if (!/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(BASE)) {
  console.error("Nur gegen einen lokalen Server (BASE=http://127.0.0.1:…), nie gegen den echten");
  process.exit(2);
}
const H = { Authorization: `Bearer ${KEY}` };
let failures = 0, passes = 0;
const ok = (cond, msg, extra) => {
  if (cond) { passes++; console.log("  ok  ", msg); }
  else { failures++; console.log("  FAIL", msg, extra !== undefined ? JSON.stringify(extra).slice(0, 400) : ""); }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const uuid = () => crypto.randomUUID().toUpperCase();

async function api(method, path, { json, body, headers } = {}) {
  const h = { ...H, ...(headers || {}) };
  let b = body;
  if (json !== undefined) { b = JSON.stringify(json); h["content-type"] = "application/json"; }
  const r = await fetch(BASE + path, { method, headers: h, body: b });
  const ct = r.headers.get("content-type") || "";
  const data = ct.includes("json") ? await r.json() : new Uint8Array(await r.arrayBuffer());
  return { status: r.status, data, ct };
}

const PNG = (n = 200) => { const b = new Uint8Array(n); b.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]); for (let i = 8; i < n; i++) b[i] = (i * 7) & 255; return b; };
const JPG = (n = 300) => { const b = new Uint8Array(n); b.set([0xff, 0xd8, 0xff, 0xe0]); for (let i = 4; i < n; i++) b[i] = (i * 13) & 255; return b; };

const PDF = (n = 400) => { const b = new Uint8Array(n); b.set([0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x37]); for (let i = 8; i < n; i++) b[i] = (i * 11) & 255; return b; };

function form(meta, { q = PNG(), p = JPG(), qName = "question.png", pName = "page.jpg", metaAsFile = false, ctx = null, ctxName = "pages.pdf" } = {}) {
  const f = new FormData();
  if (meta !== undefined) {
    if (metaAsFile) f.append("meta", new Blob([JSON.stringify(meta)], { type: "application/json" }), "meta.json");
    else f.append("meta", JSON.stringify(meta));
  }
  if (q) qName ? f.append("question", new Blob([q], { type: "image/png" }), qName) : f.append("question", new TextDecoder("latin1").decode(q));
  if (p) pName ? f.append("page", new Blob([p], { type: "image/jpeg" }), pName) : f.append("page", new TextDecoder("latin1").decode(p));
  if (ctx) ctxName ? f.append("pages", new Blob([ctx], { type: "application/pdf" }), ctxName) : f.append("pages", new TextDecoder("latin1").decode(ctx));
  return f;
}
const createAsk = (doc, id, meta, opts) => api("PUT", `/api/doc/${doc}/asks/${id}`, { body: form(meta, opts) });
const anchor = (page = 2, x = 100, y = 200) => ({ page, x, y, w: 150, h: 40 });

function socket(path) {
  const url = BASE.replace(/^http/, "ws") + path;
  const ws = new WebSocket(url, { headers: H });
  const msgs = [];
  ws.onmessage = (e) => msgs.push(typeof e.data === "string" ? e.data : "<bin>");
  const opened = new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  return { ws, msgs, opened, json: () => msgs.filter((m) => m.startsWith("{")).map((m) => JSON.parse(m)) };
}

async function newDoc(title = "Test") {
  const id = uuid(), now = Date.now() / 1000;
  const r = await api("PUT", `/api/library/${id}`, { json: { id, title, kind: "pdf", created: now, modified: now, pageCount: 5, pagesVersion: 0 } });
  if (r.status !== 200) throw new Error("newDoc " + r.status);
  return id;
}

async function main() {
  console.log("== setup");
  const doc = await newDoc("Analysis Blatt 3");
  const other = await newDoc("Anderes");
  const app = socket(`/api/doc/${doc}/ws`);
  const appOther = socket(`/api/doc/${other}/ws`);
  const helper = socket(`/api/asks/ws`);
  await Promise.all([app.opened, appOther.opened, helper.opened]);
  await sleep(200);
  ok(app.json().some((m) => m.type === "presence"), "app socket connected (presence)");

  // ping/pong auto-response
  helper.ws.send("ping");
  await sleep(300);
  ok(helper.msgs.includes("pong"), "helper ping answered with pong", helper.msgs);

  console.log("== create");
  const a1 = uuid();
  let r = await createAsk(doc, a1, { anchor: anchor(), pv: 0, effort: "thorough", created: 1763300000.5, from: "iPad" });
  ok(r.status === 200 && r.data.asks.length === 1, "create 200 with list of 1", r);
  const v1 = r.data.v;
  const ask = r.data.asks[0];
  ok(ask.id === a1 && ask.status === "open" && ask.effort === "thorough" && ask.from === "iPad" && ask.anchor.page === 2 && ask.created === 1763300000.5, "public ask shape", ask);
  ok(!("claim" in ask) && !("lease" in ask), "no claim/lease in the public ask", ask);
  await sleep(300);
  ok(app.json().some((m) => m.type === "asks" && m.v === v1), "app got asks hint with v", app.json());
  ok(!appOther.json().some((m) => m.type === "asks"), "other doc's app got no hint");
  ok(helper.json().some((m) => m.type === "ask"), "helper got ask push", helper.msgs);

  // idempotent create
  r = await createAsk(doc, a1, { anchor: anchor(4), pv: 0, effort: "quick", created: 1, from: "iPhone" });
  ok(r.status === 200 && r.data.v === v1 && r.data.asks.length === 1 && r.data.asks[0].anchor.page === 2, "repeated create changes nothing", r.data);

  console.log("== errors");
  r = await createAsk(doc, "not-a-uuid", { anchor: anchor() });
  ok(r.status === 400 && r.data.code === "bad-id", "bad id 400", r);
  r = await createAsk(uuid(), uuid(), { anchor: anchor() });
  ok(r.status === 404 && r.data.code === "no-doc", "unknown doc 404 no-doc", r);
  r = await createAsk(doc, uuid(), { anchor: anchor() }, { qName: null });
  ok(r.status === 400 && r.data.code === "bad-body", "question part without filename 400", r);
  r = await createAsk(doc, uuid(), { anchor: { page: -1, x: 0, y: 0, w: 1, h: 1 } });
  ok(r.status === 400 && r.data.code === "bad-body", "bad anchor 400", r);
  r = await createAsk(doc, uuid(), undefined);
  ok(r.status === 400 && r.data.code === "bad-body", "missing meta 400", r);
  r = await createAsk(doc, uuid(), { anchor: anchor() }, { q: new Uint8Array([1, 2, 3, 4, 5]) });
  ok(r.status === 400 && r.data.code === "bad-body", "not an image 400", r);
  r = await api("PUT", `/api/doc/${doc}/asks/${uuid()}`, { json: { anchor: anchor() } });
  ok(r.status === 400 && r.data.code === "bad-body", "JSON instead of multipart 400", r);
  r = await createAsk(doc, uuid(), { anchor: anchor() }, { q: PNG(4 * 1024 * 1024 + 10) });
  ok(r.status === 413 && r.data.code === "too-large", "question too large 413", r);
  const metaFile = uuid();
  r = await createAsk(doc, metaFile, { anchor: anchor(1), pv: 0 }, { metaAsFile: true });
  ok(r.status === 200 && r.data.asks.some((a) => a.id === metaFile && a.effort === "quick"), "meta sent as a file part also works; default effort quick", r.data);
  r = await api("DELETE", `/api/doc/${doc}/asks/${metaFile}`);
  ok(r.status === 200 && !r.data.asks.some((a) => a.id === metaFile), "delete open ask", r.data);
  r = await api("GET", `/api/asks/${metaFile}/question`);
  ok(r.status === 404, "deleted ask's image gone", r.status);

  console.log("== helper: open, claim, images");
  r = await api("GET", "/api/asks/open");
  ok(r.status === 200 && r.data.asks.length === 1 && r.data.asks[0].id === a1 && r.data.asks[0].effort === "thorough" && r.data.asks[0].retry === false && r.data.next === null, "open lists the ask", r.data);
  const before = app.json().length;
  r = await api("POST", `/api/asks/${a1}/claim`, { json: { lease: 900 } });
  ok(r.status === 200 && typeof r.data.claim === "string" && r.data.doc.title === "Analysis Blatt 3" && r.data.doc.kind === "pdf" && r.data.doc.hasPDF === false && r.data.images.question.size === 200 && r.data.images.page.type === "image/jpeg" && r.data.effort === "thorough" && r.data.anchor.page === 2, "claim returns job", r.data);
  const claim = r.data.claim;
  await sleep(300);
  ok(app.json().length > before && app.json().at(-1).type === "asks", "app hint on claim");
  r = await api("GET", `/api/doc/${doc}/asks`);
  ok(r.data.asks[0].status === "claimed", "list shows claimed", r.data);
  r = await api("POST", `/api/asks/${a1}/claim`, { json: { lease: 900 } });
  ok(r.status === 409 && r.data.code === "taken", "second claim 409 taken", r);
  r = await api("GET", "/api/asks/open");
  ok(r.data.asks.length === 0 && r.data.next > 800, "claimed ask not open; next ≈ lease", r.data);
  r = await api("GET", `/api/asks/${a1}/question`);
  ok(r.status === 200 && r.ct === "image/png" && r.data.length === 200 && r.data[0] === 0x89 && r.data[199] === ((199 * 7) & 255), "question image bytes intact", { status: r.status, ct: r.ct, len: r.data.length });
  r = await api("GET", `/api/asks/${a1}/page`);
  ok(r.status === 200 && r.ct === "image/jpeg" && r.data.length === 300, "page image intact", { status: r.status, ct: r.ct });
  r = await api("POST", `/api/asks/${a1}/claim`, { json: { lease: 1200, claim } });
  ok(r.status === 200 && r.data.claim === claim, "lease renewed with own claim", r.data);

  console.log("== answer");
  r = await api("PUT", `/api/asks/${a1}/answer`, { json: { claim: "wrong", markdown: "x" } });
  ok(r.status === 409 && r.data.code === "not-yours", "wrong claim 409", r);
  r = await api("PUT", `/api/asks/${a1}/answer`, { json: { claim } });
  ok(r.status === 400 && r.data.code === "bad-body", "answer without content 400", r);
  const md = "**Kurz:** Weil $f$ stetig ist, gilt $\\int_0^1 f\\,dx = F(1) - F(0)$.\n\n$$\\sum_{n=1}^\\infty \\frac{1}{n^2} = \\frac{\\pi^2}{6}$$\n\nÜmläute ✓";
  r = await api("PUT", `/api/asks/${a1}/answer`, { json: { claim, markdown: md } });
  ok(r.status === 200 && r.data.ok && r.data.v > v1, "answer accepted", r);
  const vAns = r.data.v;
  r = await api("PUT", `/api/asks/${a1}/answer`, { json: { claim, markdown: "anders" } });
  ok(r.status === 200 && r.data.v === vAns, "repeated answer: ok, unchanged", r);
  r = await api("GET", `/api/doc/${doc}/asks`);
  ok(r.data.asks[0].status === "answered" && r.data.asks[0].answer === md && r.data.v >= vAns, "list shows answer (unicode intact)", r.data);
  r = await api("GET", `/api/asks/${a1}/question`);
  ok(r.status === 404, "images deleted after answer", r.status);
  r = await api("GET", "/api/asks/open");
  ok(r.data.asks.length === 0, "answered ask not open", r.data);

  console.log("== text/markdown answer, error answer");
  const a2 = uuid();
  await createAsk(doc, a2, { anchor: anchor(0), pv: 0, from: "iPhone" });
  let c2 = (await api("POST", `/api/asks/${a2}/claim`, { json: {} })).data.claim;
  r = await api("PUT", `/api/asks/${a2}/answer?claim=${c2}`, { body: "# Antwort\n\n$x^2$", headers: { "content-type": "text/markdown; charset=utf-8" } });
  ok(r.status === 200 && r.data.ok, "text/markdown answer", r);
  r = await api("GET", `/api/doc/${doc}/asks`);
  ok(r.data.asks.find((a) => a.id === a2).answer === "# Antwort\n\n$x^2$", "markdown stored", r.data);
  const a3 = uuid();
  await createAsk(doc, a3, { anchor: anchor(0), pv: 0 });
  const c3 = (await api("POST", `/api/asks/${a3}/claim`, { json: {} })).data.claim;
  r = await api("PUT", `/api/asks/${a3}/answer`, { json: { claim: c3, error: "Bild nicht lesbar" } });
  r = await api("GET", `/api/doc/${doc}/asks`);
  const e3 = r.data.asks.find((a) => a.id === a3);
  ok(e3.status === "failed" && e3.note === "Bild nicht lesbar", "error answer → failed with note", e3);

  console.log("== release with retryAfter");
  const a4 = uuid();
  await createAsk(doc, a4, { anchor: anchor(3), pv: 0 });
  const c4 = (await api("POST", `/api/asks/${a4}/claim`, { json: {} })).data.claim;
  r = await api("PUT", `/api/asks/${a4}/answer`, { json: { claim: c4, release: true, note: "Claude-Limit erreicht, neuer Versuch um 17:00", retryAfter: 120 } });
  ok(r.status === 200 && r.data.ok, "release ok", r);
  r = await api("GET", "/api/asks/open");
  ok(r.data.asks.length === 0 && r.data.next >= 115 && r.data.next <= 121, "released ask hidden until retryAfter; next ≈ 120", r.data);
  r = await api("GET", `/api/doc/${doc}/asks`);
  const e4 = r.data.asks.find((a) => a.id === a4);
  ok(e4.status === "open" && e4.note.startsWith("Claude-Limit"), "app sees open with note", e4);
  r = await api("PUT", `/api/asks/${a4}/answer`, { json: { claim: c4, release: true } });
  ok(r.status === 409, "repeated release with old claim → 409 (helper treats as done)", r);
  r = await api("GET", `/api/asks/${a4}/page`);
  ok(r.status === 200, "released ask keeps its images", r.status);
  // a deferred open ask can still be claimed directly; the new claim clears the note
  r = await api("POST", `/api/asks/${a4}/claim`, { json: {} });
  ok(r.status === 200, "deferred ask claimable directly", r);
  const c4b = r.data.claim;
  r = await api("GET", `/api/doc/${doc}/asks`);
  ok(r.data.asks.find((a) => a.id === a4).note === null, "claim clears the note");

  console.log("== delete while claimed → helper cancel; late answer → gone");
  const nHelper = helper.json().length;
  r = await api("DELETE", `/api/doc/${doc}/asks/${a4}`);
  ok(r.status === 200 && !r.data.asks.some((a) => a.id === a4), "deleted", r.data);
  await sleep(300);
  ok(helper.json().slice(nHelper).some((m) => m.type === "cancel" && m.id === a4), "helper got cancel", helper.json().slice(nHelper));
  r = await api("PUT", `/api/asks/${a4}/answer`, { json: { claim: c4b, markdown: "zu spät" } });
  ok(r.status === 404 && r.data.code === "gone", "late answer 404 gone", r);
  r = await api("POST", `/api/asks/${a4}/claim`, { json: {} });
  ok(r.status === 404 && r.data.code === "gone", "claim deleted 404 gone", r);
  r = await api("DELETE", `/api/doc/${doc}/asks/${a4}`);
  ok(r.status === 200, "repeated delete ok (idempotent)", r.status);
  r = await api("DELETE", `/api/doc/${other}/asks/${a2}`);
  ok(r.status === 200 && (await api("GET", `/api/doc/${doc}/asks`)).data.asks.some((a) => a.id === a2), "delete via wrong doc does nothing");

  console.log("== lease expiry and retries (needs the 1 s minimum lease, SHORT_LEASE=1)");
  if (process.env.SHORT_LEASE === "1") {
  const a5 = uuid();
  await createAsk(doc, a5, { anchor: anchor(1), pv: 0 });
  r = await api("POST", `/api/asks/${a5}/claim`, { json: { lease: 1 } });
  const c5 = r.data.claim;
  await sleep(1300);
  r = await api("GET", "/api/asks/open");
  ok(r.data.asks.some((a) => a.id === a5 && a.retry === true), "expired claim listed with retry: true", r.data);
  // the stale helper can still answer while nobody re-claimed it
  r = await api("PUT", `/api/asks/${a5}/answer`, { json: { claim: c5, markdown: "noch rechtzeitig" } });
  ok(r.status === 200, "answer after lease expiry, not re-claimed: accepted", r);
  const a6 = uuid();
  await createAsk(doc, a6, { anchor: anchor(1), pv: 0 });
  let last;
  for (let i = 0; i < 4; i++) {
    r = await api("POST", `/api/asks/${a6}/claim`, { json: { lease: 1 } });
    last = r;
    if (r.status !== 200) break;
    await sleep(1200);
  }
  ok(last.status === 409 && last.data.code === "failed", "claim after the third expiry → failed", last);
  r = await api("GET", `/api/doc/${doc}/asks`);
  const e6 = r.data.asks.find((a) => a.id === a6);
  ok(e6.status === "failed" && /mehrmals/.test(e6.note), "failed with note", e6);
  r = await api("GET", `/api/asks/${a6}/page`);
  ok(r.status === 404, "failed ask's images deleted", r.status);
  } else console.log("  (skipped)");

  console.log("== move after page changes");
  const a7 = uuid(), a8 = uuid();
  await createAsk(doc, a7, { anchor: anchor(3), pv: 100 });
  await createAsk(doc, a8, { anchor: anchor(4), pv: 100 });
  r = await api("PATCH", `/api/doc/${doc}/asks`, { json: { pv: 50, anchors: { [a7]: anchor(9) } } });
  ok(r.data.asks.find((a) => a.id === a7).anchor.page === 3, "older pv does not move", r.data);
  const nApp = app.json().length;
  r = await api("PATCH", `/api/doc/${doc}/asks`, { json: { pv: 200, anchors: { [a7]: anchor(2, 100, 200), [a8]: null, [uuid()]: anchor(1) } } });
  const m7 = r.data.asks.find((a) => a.id === a7);
  ok(m7.anchor.page === 2 && m7.pv === 200 && !r.data.asks.some((a) => a.id === a8), "move + delete via null", r.data);
  r = await api("GET", `/api/asks/${a8}/question`);
  ok(r.status === 404, "removed ask's images deleted", r.status);
  await sleep(300);
  ok(app.json().length > nApp, "app hint(s) on move");
  r = await api("PATCH", `/api/doc/${doc}/asks`, { json: { pv: 200, anchors: { [a7]: anchor(2, 100, 200) } } });
  ok(r.status === 200 && r.data.asks.find((a) => a.id === a7).anchor.page === 2, "same pv repeat ok", r.data);
  r = await api("PATCH", `/api/doc/${doc}/asks`, { json: { pv: 300, anchors: { [a7]: anchor(-1, 100, 200) } } });
  ok(r.status === 200 && r.data.asks.find((a) => a.id === a7).anchor.page === -1 && r.data.asks.find((a) => a.id === a7).pv === 300, "page -1 via PATCH (page deleted, undo possible)", r.data);
  r = await api("PATCH", `/api/doc/${doc}/asks`, { json: { pv: 400, anchors: { [a7]: anchor(2, 100, 200) } } });
  ok(r.data.asks.find((a) => a.id === a7).anchor.page === 2 && r.data.asks.find((a) => a.id === a7).pv === 400, "undo restores the page", r.data);
  r = await api("PATCH", `/api/doc/${doc}/asks`, { json: { pv: 500, anchors: { [a7]: anchor(-2) } } });
  ok(r.data.asks.find((a) => a.id === a7).anchor.page === 2, "page -2 ignored", r.data);
  r = await createAsk(doc, uuid(), { anchor: anchor(-1), pv: 1 });
  ok(r.status === 400 && r.data.code === "bad-body", "PUT with page -1 rejected", r);

  console.log("== deleted asks stay deleted; asked on an older page version");
  // Noch einmal hochgeladen, nachdem sie anderswo gelöscht wurde (die Antwort aufs erste Hochladen ging verloren)
  const g1 = uuid();
  await createAsk(doc, g1, { anchor: anchor(1), pv: 0 });
  r = await api("DELETE", `/api/doc/${doc}/asks/${g1}`);
  ok(r.status === 200 && !r.data.asks.some((a) => a.id === g1), "deleted", r.data);
  await sleep(300);
  const nHelper2 = helper.json().length;
  r = await createAsk(doc, g1, { anchor: anchor(1), pv: 0 });
  ok(r.status === 200 && !r.data.asks.some((a) => a.id === g1), "re-upload after delete: 200, not created again", r.data);
  r = await api("GET", "/api/asks/open");
  ok(!r.data.asks.some((a) => a.id === g1), "not open for the helper", r.data);
  await sleep(300);
  ok(!helper.json().slice(nHelper2).some((m) => m.type === "ask"), "no ask push for it", helper.json().slice(nHelper2));
  // Gelöscht, bevor sie ankam: kommt sie später, entsteht sie nicht
  const g2 = uuid();
  r = await api("DELETE", `/api/doc/${doc}/asks/${g2}`);
  ok(r.status === 200, "delete of an ask the server has not seen: ok", r.status);
  r = await createAsk(doc, g2, { anchor: anchor(1), pv: 0 });
  ok(r.status === 200 && !r.data.asks.some((a) => a.id === g2), "upload after its delete: not created", r.data);
  // Mit ihrer Seite entfernt (PATCH null, oben a8): ebenso
  r = await createAsk(doc, a8, { anchor: anchor(4), pv: 100 });
  ok(r.status === 200 && !r.data.asks.some((a) => a.id === a8), "re-upload of an ask removed with its page: not created", r.data);
  // Gefragt auf einem älteren Seitenstand, als der Server kennt
  const pvDoc = await newDoc("Seiten");
  const t2 = Date.now() / 1000;
  r = await api("PUT", `/api/library/${pvDoc}`, { json: { id: pvDoc, title: "Seiten", kind: "pdf", created: t2, modified: t2 + 5, pageCount: 4, pagesVersion: 7000 } });
  ok(r.status === 200 && r.data.pagesVersion === 7000, "page version raised", r.data);
  r = await createAsk(pvDoc, uuid(), { anchor: anchor(1), pv: 6999 });
  ok(r.status === 409 && r.data.code === "stale-pages", "older page version → 409 stale-pages", r);
  r = await createAsk(pvDoc, uuid(), { anchor: anchor(1), pv: 7000 });
  ok(r.status === 200 && r.data.asks.length === 1, "same page version accepted", r);
  r = await createAsk(pvDoc, uuid(), { anchor: anchor(1), pv: 8000 });
  ok(r.status === 200 && r.data.asks.length === 2, "newer page version (device ahead of the server) accepted", r);
  for (const a of (await api("GET", `/api/doc/${pvDoc}/asks`)).data.asks) await api("DELETE", `/api/doc/${pvDoc}/asks/${a.id}`);

  console.log("== cap of open asks");
  const capDoc = await newDoc("Cap");
  let n429 = null;
  for (let i = 0; i < 60; i++) {
    r = await createAsk(capDoc, uuid(), { anchor: anchor(0), pv: 0 });
    if (r.status === 429) { n429 = i; break; }
  }
  const openNow = (await api("GET", "/api/asks/open")).data.asks.length;
  ok(n429 !== null && r.data.code === "too-many", `429 too-many after ${n429} creates (open total ${openNow})`, r);

  console.log("== tombstone removes the doc's asks");
  r = await api("GET", `/api/doc/${capDoc}/asks`);
  const capIds = r.data.asks.map((a) => a.id);
  const now = Date.now() / 1000;
  r = await api("PUT", `/api/library/${capDoc}`, { json: { id: capDoc, title: "Cap", kind: "pdf", created: now, modified: now + 10, deleted: true } });
  ok(r.status === 200 && r.data.deleted === true, "doc tombstoned", r.data);
  r = await api("GET", `/api/doc/${capDoc}/asks`);
  ok(r.data.asks.length === 0, "asks gone with the doc", r.data.asks.length);
  r = await api("GET", `/api/asks/${capIds[0]}/question`);
  ok(r.status === 404, "their images gone", r.status);
  r = await api("GET", "/api/asks/open");
  ok(!r.data.asks.some((a) => a.doc === capDoc), "none of them open any more", r.data.asks.length);
  r = await createAsk(capDoc, uuid(), { anchor: anchor(0) });
  ok(r.status === 404 && r.data.code === "no-doc", "create on deleted doc 404 no-doc", r);

  console.log("== existing API unchanged");
  r = await api("GET", "/api/library");
  ok(r.status === 200 && Array.isArray(r.data.docs) && r.data.docs.some((d) => d.id === doc), "library ok", r.status);
  r = await api("POST", `/api/doc/${doc}/sync`, { json: { since: 0, add: [{ id: "s1", data: "abc" }], remove: [] } });
  ok(r.status === 200 && r.data.seq > 0, "stroke sync ok", r.data);
  r = await fetch(BASE + "/api/asks/open");
  ok(r.status === 401, "no key → 401", r.status);
  const noKey = new WebSocket(BASE.replace(/^http/, "ws") + "/api/asks/ws");
  const res = await new Promise((resolve) => { noKey.onopen = () => resolve("open"); noKey.onerror = () => resolve("error"); noKey.onclose = () => resolve("closed"); });
  ok(res !== "open", "helper socket without key refused", res);
  r = await api("GET", "/api/asks/ws");
  ok(r.status === 426, "helper ws without upgrade 426", r.status);

  // guests never see asks hints
  console.log("== guest sees no asks hint");
  const token = (await api("POST", `/api/share/${doc}`)).data.token;
  const guest = new WebSocket(BASE.replace(/^http/, "ws") + `/s/${token}/ws`);
  const gm = [];
  guest.onmessage = (e) => gm.push(String(e.data));
  await new Promise((res) => (guest.onopen = res));
  await createAsk(doc, uuid(), { anchor: anchor(0), pv: 0 });
  await sleep(400);
  ok(!gm.some((m) => m.includes('"asks"') || m.includes('"ask"')), "guest got no asks/ask message", gm);
  guest.close();

  console.log("== quick hand-backs count like expired claims; count: false and long pauses do not");
  const a9 = uuid();
  await createAsk(doc, a9, { anchor: anchor(2), pv: 0 });
  let rel;
  for (let i = 0; i < 4; i++) {
    rel = await api("POST", `/api/asks/${a9}/claim`, { json: {} });
    if (rel.status !== 200) break;
    r = await api("PUT", `/api/asks/${a9}/answer`, { json: { claim: rel.data.claim, release: true, retryAfter: 120, note: "Fehler am Mac, neuer Versuch" } });
    if (r.status !== 200) break;
  }
  ok(rel.status === 409 && rel.data.code === "failed", "claim after the third quick hand-back → failed, no endless cycling", rel);
  const e9 = (await api("GET", `/api/doc/${doc}/asks`)).data.asks.find((a) => a.id === a9);
  ok(e9.status === "failed" && /mehrmals/.test(e9.note), "failed with note", e9);
  const a10 = uuid();
  await createAsk(doc, a10, { anchor: anchor(2), pv: 0 });
  rel = await api("POST", `/api/asks/${a10}/claim`, { json: {} });
  for (let i = 0; i < 5 && rel.status === 200; i++) {
    await api("PUT", `/api/asks/${a10}/answer`, { json: { claim: rel.data.claim, release: true, retryAfter: 0, count: false, note: "Claude am Mac ist abgemeldet" } });
    rel = await api("POST", `/api/asks/${a10}/claim`, { json: {} });
  }
  ok(rel.status === 200, "hand-backs with count: false (logged out, restart) never use up the retries", rel);
  for (let i = 0; i < 4 && rel.status === 200; i++) {
    await api("PUT", `/api/asks/${a10}/answer`, { json: { claim: rel.data.claim, release: true, retryAfter: 3600, note: "Claude-Limit erreicht" } });
    rel = await api("POST", `/api/asks/${a10}/claim`, { json: {} });
  }
  ok(rel.status === 200, "long pauses (usage limit) never use up the retries", rel);

  console.log("== context pages (meta.span, meta.pages and the PDF pages: the pages around the question)");
  {
    const ctxBytes = PDF(5000);
    const c1 = uuid();
    r = await createAsk(doc, c1, { anchor: anchor(3), pv: 0, effort: "thorough", span: [0, 5], pages: [0, 1, 2, 4] }, { ctx: ctxBytes });
    ok(r.status === 200 && r.data.asks.some((a) => a.id === c1), "ask with pages accepted", r);
    const pub = r.data.asks.find((a) => a.id === c1);
    ok(!("pages" in pub) && !("span" in pub), "span and pages not in the public ask", pub);
    r = await api("POST", `/api/asks/${c1}/claim`, { json: {} });
    ok(r.status === 200 && JSON.stringify(r.data.span) === "[0,5]" && JSON.stringify(r.data.pages) === "[0,1,2,4]" && r.data.images.pages?.size === 5000 && r.data.images.pages?.type === "application/pdf", "claim gives span, pages and the PDF", r.data);
    const cc1 = r.data.claim;
    r = await api("GET", `/api/asks/${c1}/pages`);
    ok(r.status === 200 && r.data.length === 5000 && r.data[0] === 0x25 && r.data[4999] === ctxBytes[4999], "helper downloads the pages PDF", r.status);
    r = await api("PUT", `/api/asks/${c1}/answer`, { json: { claim: cc1, markdown: "mit Seiten" } });
    ok(r.status === 200, "answered", r);
    r = await api("GET", `/api/asks/${c1}/pages`);
    ok(r.status === 404, "pages PDF gone after the answer (like question and page)", r.status);
    r = await api("GET", `/api/asks/${c1}/question`);
    ok(r.status === 404, "question gone after the answer as before", r.status);

    // No other page with handwriting in the span: span and an empty list, no PDF
    const c0 = uuid();
    r = await createAsk(doc, c0, { anchor: anchor(2), pv: 0, span: [0, 3], pages: [] }, {});
    let cl = await api("POST", `/api/asks/${c0}/claim`, { json: {} });
    ok(r.status === 200 && cl.status === 200 && JSON.stringify(cl.data.span) === "[0,3]" && JSON.stringify(cl.data.pages) === "[]" && cl.data.images.pages === null, "span without written pages: empty list, no PDF", cl.data);
    await api("PUT", `/api/asks/${c0}/answer`, { json: { claim: cl.data.claim, markdown: "ok" } });

    // Pages moved after the upload (new pages version, or the question on another page): numbers no longer fit
    for (const [name, change] of [["new pages version", { pv: 4, page: 5 }], ["same version, other page", { pv: 0, page: 6 }]]) {
      const cm = uuid();
      await createAsk(doc, cm, { anchor: anchor(5), pv: 0, span: [2, 6], pages: [3] }, { ctx: PDF(700) });
      const mv = await api("PATCH", `/api/doc/${doc}/asks`, { json: { pv: change.pv, anchors: { [cm]: anchor(change.page) } } });
      cl = await api("POST", `/api/asks/${cm}/claim`, { json: {} });
      ok(mv.status === 200 && cl.status === 200 && cl.data.anchor.page === change.page && cl.data.span === null && cl.data.pages === null, `${name}: span and pages left out`, { mv: mv.status, claim: cl.data });
      await api("PUT", `/api/asks/${cm}/answer`, { json: { claim: cl.data.claim, markdown: "ok" } });
    }
    // Moved to the same place (nothing changed): still there
    {
      const cs = uuid();
      await createAsk(doc, cs, { anchor: anchor(5), pv: 2, span: [2, 6], pages: [3] }, { ctx: PDF(700) });
      await api("PATCH", `/api/doc/${doc}/asks`, { json: { pv: 2, anchors: { [cs]: { ...anchor(5), x: 99 } } } });
      cl = await api("POST", `/api/asks/${cs}/claim`, { json: {} });
      ok(cl.status === 200 && JSON.stringify(cl.data.span) === "[2,6]" && JSON.stringify(cl.data.pages) === "[3]", "same page and version: span and pages stay", cl.data);
      await api("PUT", `/api/asks/${cs}/answer`, { json: { claim: cl.data.claim, markdown: "ok" } });
    }

    // The document got a newer page version (pages inserted elsewhere) before this ask moved along: numbers may be off
    {
      const pvd = await newDoc("Seitenstand");
      const cp = uuid();
      await createAsk(pvd, cp, { anchor: anchor(3), pv: 0, span: [0, 4], pages: [1] }, { ctx: PDF(700) });
      const t3 = Date.now() / 1000 + 60;
      const up = await api("PUT", `/api/library/${pvd}`, { json: { id: pvd, title: "Seitenstand", kind: "pdf", created: t3, modified: t3, pageCount: 6, pagesVersion: 1 } });
      cl = await api("POST", `/api/asks/${cp}/claim`, { json: {} });
      ok(up.status === 200 && up.data.pagesVersion === 1 && cl.status === 200 && cl.data.anchor.page === 3 && cl.data.span === null && cl.data.pages === null,
        "newer page version of the document, ask not moved yet: span and pages left out", { up: up.data, claim: cl.data });
      await api("PUT", `/api/asks/${cp}/answer`, { json: { claim: cl.data.claim, markdown: "ok" } });
    }

    // An old app (nothing about the pages): as before
    const cOld = uuid();
    r = await createAsk(doc, cOld, { anchor: anchor(2), pv: 0 }, {});
    cl = await api("POST", `/api/asks/${cOld}/claim`, { json: {} });
    ok(r.status === 200 && cl.status === 200 && cl.data.span === null && cl.data.pages === null && cl.data.images.pages === null, "old app: span and pages null", cl.data);
    await api("PUT", `/api/asks/${cOld}/answer`, { json: { claim: cl.data.claim, markdown: "ok" } });

    // Anything wrong: the ask counts, the pages are left out
    const variants = [
      ["no meta.span", { span: undefined, pages: [1] }, { ctx: ctxBytes }],
      ["no meta.pages", { pages: undefined }, { ctx: ctxBytes }],
      ["span not a pair", { span: [1], pages: [1] }, { ctx: ctxBytes }],
      ["span backwards", { span: [4, 1], pages: [1] }, { ctx: ctxBytes }],
      ["span too long", { span: [0, 21], pages: [1] }, { ctx: ctxBytes }],
      ["negative span", { span: [-1, 3], pages: [1] }, { ctx: ctxBytes }],
      ["page outside the span", { span: [2, 5], pages: [1] }, { ctx: ctxBytes }],
      ["empty list with a PDF", { pages: [] }, { ctx: ctxBytes }],
      ["duplicate pages", { pages: [1, 1] }, { ctx: ctxBytes }],
      ["fraction", { pages: [1.5] }, { ctx: ctxBytes }],
      ["too many pages", { span: [0, 20], pages: Array.from({ length: 13 }, (_, i) => i) }, { ctx: ctxBytes }],
      ["not a PDF", { pages: [1] }, { ctx: JPG(800) }],
      ["too large", { pages: [1] }, { ctx: PDF(8 * 1024 * 1024 + 1) }],
      ["part without filename (text)", { pages: [1] }, { ctx: PDF(300), ctxName: null }],
      ["list without part", { pages: [1] }, {}],
      // Keine Zahlen: nicht umwandeln (aus null würde Seite 0) und nie einen Fehler werfen
      ["null in the span", { span: [null, 3], pages: [1] }, { ctx: ctxBytes }],
      ["page as text", { pages: ["1"] }, { ctx: ctxBytes }],
      ["page true", { pages: [true] }, { ctx: ctxBytes }],
      ["object that cannot become a number", { span: [{ valueOf: 1, toString: 1 }, 6], pages: [1] }, { ctx: ctxBytes }],
    ];
    for (const [name, extra, opts] of variants) {
      const id = uuid();
      const meta = { anchor: anchor(2), pv: 0, span: [0, 6], ...extra };
      for (const k of ["span", "pages"]) if (meta[k] === undefined) delete meta[k];
      r = await createAsk(doc, id, meta, opts);
      const created = r.status === 200 && r.data.asks.some((a) => a.id === id);
      const claim = created ? await api("POST", `/api/asks/${id}/claim`, { json: {} }) : null;
      const blob = created ? await api("GET", `/api/asks/${id}/pages`) : null;
      ok(created && claim.status === 200 && claim.data.span === null && claim.data.pages === null && claim.data.images.pages === null && blob.status === 404,
        `${name}: ask created, pages left out`, { status: r.status, span: claim?.data?.span, pages: claim?.data?.pages, images: claim?.data?.images, blob: blob?.status });
      if (claim?.status === 200) await api("PUT", `/api/asks/${id}/answer`, { json: { claim: claim.data.claim, markdown: "ok" } });
    }

    // Exactly 12 pages, a span of 21 and exactly the size limit are fine
    const c2 = uuid();
    r = await createAsk(doc, c2, { anchor: anchor(12), pv: 0, effort: "thorough", span: [0, 20], pages: Array.from({ length: 12 }, (_, i) => i) }, { ctx: PDF(8 * 1024 * 1024) });
    cl = await api("POST", `/api/asks/${c2}/claim`, { json: {} });
    ok(r.status === 200 && cl.status === 200 && cl.data.pages?.length === 12 && JSON.stringify(cl.data.span) === "[0,20]" && cl.data.images.pages?.size === 8 * 1024 * 1024, "12 pages, span of 21 and 8 MB accepted", cl.data);
    r = await api("GET", `/api/asks/${c2}/pages`);
    ok(r.status === 200 && r.data.length === 8 * 1024 * 1024, "8 MB PDF comes back whole (several chunks)", r.data.length);
    // Deleting the ask removes the PDF too
    r = await api("DELETE", `/api/doc/${doc}/asks/${c2}`);
    r = await api("GET", `/api/asks/${c2}/pages`);
    ok(r.status === 404, "pages PDF gone after deleting the ask", r.status);

    // A repeated upload of the same ask (answer lost) changes nothing, even with other pages
    const c3 = uuid();
    await createAsk(doc, c3, { anchor: anchor(1), pv: 0, span: [0, 2], pages: [0] }, { ctx: PDF(600) });
    r = await createAsk(doc, c3, { anchor: anchor(1), pv: 0, span: [0, 2], pages: [0, 2] }, { ctx: PDF(900) });
    cl = await api("POST", `/api/asks/${c3}/claim`, { json: {} });
    ok(r.status === 200 && JSON.stringify(cl.data.pages) === "[0]" && cl.data.images.pages?.size === 600, "repeat upload keeps the first pages", cl.data);
    await api("PUT", `/api/asks/${c3}/answer`, { json: { claim: cl.data.claim, markdown: "ok" } });
  }

  console.log("== held for a newer page state (the PDF is still going up): woken when the page state arrives; age");
  {
    // Der Helfer stellt eine Frage zurück, deren Seitenstand der Server noch nicht hat; eine andere wartet aufs Nutzungslimit
    const hd = await newDoc("Gehalten"), h1 = uuid(), h2 = uuid();
    await createAsk(hd, h1, { anchor: anchor(1), pv: 200, created: Date.now() / 1000 - 3600 });
    await createAsk(hd, h2, { anchor: anchor(2), pv: 0 });
    const k1 = await api("POST", `/api/asks/${h1}/claim`, { json: {} });
    ok(k1.status === 200 && typeof k1.data.age === "number" && k1.data.age >= 0 && k1.data.age < 10 && k1.data.created < Date.now() / 1000 - 3000,
      "age counts from the arrival at the server, not from the device's created", { age: k1.data.age, created: k1.data.created });
    const k2 = await api("POST", `/api/asks/${h2}/claim`, { json: {} });
    await api("PUT", `/api/asks/${h1}/answer`, { json: { claim: k1.data.claim, release: true, retryAfter: 3600, count: false, note: "Das geänderte PDF ist noch nicht oben" } });
    await api("PUT", `/api/asks/${h2}/answer`, { json: { claim: k2.data.claim, release: true, retryAfter: 3600, count: false, note: "Claude-Limit erreicht" } });
    let o = await api("GET", "/api/asks/open");
    ok(!o.data.asks.some((x) => x.id === h1 || x.id === h2), "both held", o.data);
    // Ein Gerät ohne die Seitenänderung (älterer modified, alter Seitenstand) weckt nichts
    const t0 = Date.now() / 1000, nHelper = helper.json().length;
    await api("PUT", `/api/library/${hd}`, { json: { id: hd, title: "Gehalten", kind: "pdf", created: t0, modified: t0 + 1, pageCount: 5, pagesVersion: 0 } });
    o = await api("GET", "/api/asks/open");
    ok(!o.data.asks.some((x) => x.id === h1 || x.id === h2), "meta without a newer page state: still held", o.data);
    // Der neue Seitenstand kommt (die App lädt ihn nach dem PDF hinauf)
    await api("PUT", `/api/library/${hd}`, { json: { id: hd, title: "Gehalten", kind: "pdf", created: t0, modified: t0 + 2, pageCount: 6, pagesVersion: 200 } });
    o = await api("GET", "/api/asks/open");
    ok(o.data.asks.some((x) => x.id === h1) && !o.data.asks.some((x) => x.id === h2), "the question of the new page state is due at once, the one held for the limit is not", o.data);
    await sleep(300);
    ok(helper.json().slice(nHelper).filter((m) => m.type === "ask").length === 1, "helper told once", helper.json().slice(nHelper));
    const mine = (await api("GET", `/api/doc/${hd}/asks`)).data.asks.find((x) => x.id === h1);
    ok(mine.status === "open" && mine.note === "Das geänderte PDF ist noch nicht oben", "the app still sees it waiting until the helper takes it", mine);
    // Eine weitere Seitenänderung ohne zurückgestellte Fragen sagt dem Helfer nichts
    const nHelper2 = helper.json().length;
    await api("PUT", `/api/library/${hd}`, { json: { id: hd, title: "Gehalten", kind: "pdf", created: t0, modified: t0 + 3, pageCount: 7, pagesVersion: 300 } });
    await sleep(300);
    ok(!helper.json().slice(nHelper2).some((m) => m.type === "ask"), "page change without held questions: helper not told", helper.json().slice(nHelper2));
    // Kommt der Seitenstand zwischen Übernahme und Rückgabe, gibt es niemanden zu wecken: Die Rückgabe mit waitPv prüft selbst
    const h3 = uuid();
    await createAsk(hd, h3, { anchor: anchor(1), pv: 400 });
    const k3 = await api("POST", `/api/asks/${h3}/claim`, { json: {} });
    await api("PUT", `/api/library/${hd}`, { json: { id: hd, title: "Gehalten", kind: "pdf", created: t0, modified: t0 + 4, pageCount: 8, pagesVersion: 400 } });
    await api("PUT", `/api/asks/${h3}/answer`, { json: { claim: k3.data.claim, release: true, retryAfter: 60, count: false, note: "Das geänderte PDF ist noch nicht oben", waitPv: 400 } });
    o = await api("GET", "/api/asks/open");
    ok(o.data.asks.some((x) => x.id === h3), "release waiting for a page state the doc already has: due at once", o.data);
    // Wartet sie auf einen Seitenstand, den das Dokument noch nicht hat: bleibt zurückgestellt
    const k3b = await api("POST", `/api/asks/${h3}/claim`, { json: {} });
    await api("PUT", `/api/asks/${h3}/answer`, { json: { claim: k3b.data.claim, release: true, retryAfter: 60, count: false, waitPv: 500 } });
    o = await api("GET", "/api/asks/open");
    ok(!o.data.asks.some((x) => x.id === h3), "waiting for a newer page state: held", o.data);
    for (const id of [h1, h2, h3]) await api("DELETE", `/api/doc/${hd}/asks/${id}`);
  }

  // Aufräumen: Offene Fragen blieben sonst für den nächsten Lauf (oder den Helfer-Test) liegen
  for (const a of (await api("GET", `/api/doc/${doc}/asks`)).data.asks) await api("DELETE", `/api/doc/${doc}/asks/${a.id}`);
  r = await api("GET", "/api/asks/open");
  ok(r.data.asks.length === 0, "nothing left open", r.data);

  app.ws.close(); appOther.ws.close(); helper.ws.close();
  console.log(`\n${passes} passed, ${failures} failed`);
  process.exit(failures ? 1 : 0);
}
main().catch((e) => { console.error(e); process.exit(2); });
