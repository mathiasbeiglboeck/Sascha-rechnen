// Test des Connectors für Claude (MCP, src/mcp.js) gegen einen lokalen Server mit Wegwerf-Schlüssel, nie gegen den echten:
//   cd native/Notizbuch/server && npx wrangler dev --ip 127.0.0.1 --port 8792 --var SECRET:testkey --persist-to <leerer Ordner>
//   BASE=http://127.0.0.1:8792 KEY=testkey node test/mcp.mjs
import { createHmac } from "node:crypto";

const BASE = process.env.BASE || "http://127.0.0.1:8792";
const KEY = process.env.KEY || "testkey";
if (!/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(BASE)) {
  console.error("Nur gegen einen lokalen Server (BASE=http://127.0.0.1:…), nie gegen den echten");
  process.exit(2);
}
let failures = 0, passes = 0;
const ok = (cond, msg, extra) => {
  if (cond) { passes++; console.log("  ok  ", msg); }
  else { failures++; console.log("  FAIL", msg, extra !== undefined ? JSON.stringify(extra).slice(0, 400) : ""); }
};
// Derselbe Schlüssel wie mcpKey im Server und connector-link.sh am Mac
const mcpKey = createHmac("sha256", KEY).update("mcp-connector").digest("base64url").slice(0, 32);
const MCP = `${BASE}/mcp/${mcpKey}`;
const H = { Authorization: `Bearer ${KEY}` };
let nextId = 1;
async function rpc(method, params, url = MCP) {
  const r = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json, text/event-stream" },
    body: JSON.stringify({ jsonrpc: "2.0", id: nextId++, method, params }),
  });
  const ct = r.headers.get("content-type") || "";
  return { status: r.status, data: ct.includes("json") ? await r.json() : await r.text() };
}
const call = async (name, args) => (await rpc("tools/call", { name, arguments: args })).data.result;
const txt = (res) => res?.content?.find((c) => c.type === "text")?.text || "";

console.log("Zugang");
let r = await rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } }, `${BASE}/mcp/falscherschluessel12345`);
ok(r.status === 404, "falscher Schlüssel → 404 (keine 401, die OAuth auslösen würde)", r);
r = await rpc("initialize", {}, `${BASE}/mcp/${createHmac("sha256", "anderer").update("mcp-connector").digest("base64url").slice(0, 32)}`);
ok(r.status === 404, "Schlüssel aus anderem SECRET → 404");
ok((await fetch(`${BASE}/.well-known/oauth-protected-resource`)).status === 404, ".well-known → 404");
ok((await fetch(`${BASE}/.well-known/oauth-authorization-server`)).status === 404, "OAuth-Metadaten → 404");
ok((await fetch(MCP)).status === 405, "GET auf den Connector → 405");
ok((await fetch(`${BASE}/api/outbox/claude`, { headers: { Authorization: `Bearer ${mcpKey}` } })).status === 401,
  "Connector-Schlüssel gilt nicht für /api");
ok((await fetch(`${BASE}/`)).status === 200 && (await (await fetch(`${BASE}/`)).text()).includes("Notizbuch-Server"),
  "Startseite unverändert (das Deploy-Skript prüft sie)");

console.log("Protokoll");
r = await rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } });
ok(r.status === 200 && r.data.result?.protocolVersion === "2025-06-18", "initialize 2025-06-18", r.data);
ok(r.data.result?.capabilities?.tools && r.data.result?.serverInfo?.name === "notizbuch", "capabilities.tools, serverInfo");
ok(/Markdown/.test(r.data.result?.instructions || ""), "instructions dabei");
r = await rpc("initialize", { protocolVersion: "2024-11-05" });
ok(r.data.result?.protocolVersion === "2024-11-05", "ältere Version wird übernommen");
r = await rpc("initialize", { protocolVersion: "1999-01-01" });
ok(r.data.result?.protocolVersion === "2025-06-18", "unbekannte Version → neueste");
let n = await fetch(MCP, { method: "POST", headers: { "content-type": "application/json" },
  body: JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) });
ok(n.status === 202, "Benachrichtigung → 202");
r = await rpc("ping");
ok(r.data.result && Object.keys(r.data.result).length === 0, "ping");
r = await rpc("gibtsnicht");
ok(r.data.error?.code === -32601, "unbekannte Methode → -32601");
n = await fetch(MCP, { method: "POST", headers: { "content-type": "application/json" }, body: "{kaputt" });
ok(n.status === 400 && (await n.json()).error?.code === -32700, "kaputtes JSON → -32700");
r = await rpc("tools/list");
const names = (r.data.result?.tools || []).map((t) => t.name);
ok(names.length === 8 && names.includes("notizbuch_markdown_senden") && names.includes("notizbuch_ausgang_holen"), "tools/list: 8 Werkzeuge", names);
ok(r.data.result.tools.every((t) => t.inputSchema?.type === "object" && t.description), "jedes mit inputSchema und Beschreibung");
r = await rpc("tools/call", { name: "gibtsnicht", arguments: {} });
ok(r.data.error?.code === -32602, "unbekanntes Werkzeug → -32602");

console.log("Eingang");
const before = (await (await fetch(`${BASE}/api/library`, { headers: H })).json()).docs.length;
let res = await call("notizbuch_markdown_senden", { markdown: "# Ableitung\n\n$$f'(x) = 2x$$\n" });
ok(!res.isError && /Ableitung/.test(txt(res)), "Markdown geschickt, Titel aus der Überschrift", res);
res = await call("notizbuch_markdown_senden", { markdown: "Text ohne Überschrift", title: "Mein Titel" });
ok(/Mein Titel/.test(txt(res)), "Markdown mit eigenem Titel");
let docs = (await (await fetch(`${BASE}/api/library`, { headers: H })).json()).docs;
const md = docs.find((d) => d.title === "Ableitung");
ok(docs.length === before + 2 && md?.source === "md" && md.folder === "temp" && !md.hasPDF, "zwei neue Dokumente, Markdown ohne PDF im Ordner temp", md);
const mdText = await (await fetch(`${BASE}/api/md/${md.id}`, { headers: H })).text();
ok(mdText.includes("f'(x) = 2x"), "Markdown-Text liegt am Server");
res = await call("notizbuch_markdown_senden", { markdown: "   " });
ok(res.isError, "leeres Markdown → Fehler für das Modell");
res = await call("notizbuch_markdown_senden", {});
ok(res.isError && /markdown fehlt/.test(txt(res)), "fehlendes Markdown → Fehler");

const pdf = Buffer.from("%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n");
res = await call("notizbuch_pdf_senden", { title: "Blatt 3", pdf_base64: pdf.toString("base64") });
ok(!res.isError && /Blatt 3/.test(txt(res)), "PDF als base64", res);
docs = (await (await fetch(`${BASE}/api/library`, { headers: H })).json()).docs;
const p = docs.find((d) => d.title === "Blatt 3");
ok(p?.hasPDF && p.kind === "pdf", "PDF-Dokument mit PDF");
const back = Buffer.from(await (await fetch(`${BASE}/api/pdf/${p.id}`, { headers: H })).arrayBuffer());
ok(back.equals(pdf), "PDF unverändert am Server");
res = await call("notizbuch_pdf_senden", { title: "x", pdf_base64: "data:application/pdf;base64," + pdf.toString("base64") });
ok(!res.isError, "data:-Präfix wird abgeschnitten");
res = await call("notizbuch_pdf_senden", { title: "x", pdf_base64: Buffer.from("hallo").toString("base64") });
ok(res.isError && /kein PDF/.test(txt(res)), "kein PDF → Fehler");
res = await call("notizbuch_pdf_senden", { title: "x" });
ok(res.isError, "weder URL noch base64 → Fehler");
res = await call("notizbuch_pdf_senden", { title: "x", pdf_url: "ftp://a/b.pdf" });
ok(res.isError, "ftp-Adresse → Fehler");

console.log("Hochlade-Adresse");
res = await call("notizbuch_hochlade_link", {});
const link = (txt(res).match(/http:\/\/\S+\/up\/\d+\/[A-Za-z0-9_-]+/) || [])[0];
ok(link && link.startsWith(BASE), "Adresse mit curl-Befehl", txt(res));
let u = await fetch(`${link}?title=Hochgeladen`, { method: "POST", body: pdf });
let uj = await u.json();
ok(u.status === 200 && uj.title === "Hochgeladen", "PDF über die Adresse hochgeladen", uj);
u = await fetch(`${link}?type=md`, { method: "POST", headers: { "content-type": "text/markdown; charset=utf-8" }, body: "# Über Link\nä ö ü" });
uj = await u.json();
ok(uj.source === "md" && uj.title === "Über Link", "Markdown über die Adresse", uj);
ok((await fetch(link.replace(/.$/, (c) => (c === "A" ? "B" : "A")), { method: "POST", body: pdf })).status === 404, "falsche Signatur → 404");
const [, exp] = link.match(/\/up\/(\d+)\//);
ok((await fetch(link.replace(`/up/${exp}/`, `/up/${Number(exp) + 1}/`), { method: "POST", body: pdf })).status === 404, "verlängerte Frist → 404");
const old = Math.floor(Date.now() / 1000) - 10;
const oldSig = createHmac("sha256", KEY).update(`upload:${old}`).digest("base64url").slice(0, 32);
ok((await fetch(`${BASE}/up/${old}/${oldSig}`, { method: "POST", body: pdf })).status === 410, "abgelaufene Adresse → 410");
ok((await fetch(link)).status === 405, "GET auf die Adresse → 405");

console.log("Ausgang");
const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(100, 7)]);
const name = "Übungsblatt 3 – Seite 1.png";
await fetch(`${BASE}/api/outbox/claude/${encodeURIComponent(name)}`, { method: "PUT", headers: { ...H, "content-type": "image/png" }, body: png });
await fetch(`${BASE}/api/outbox/claude/${encodeURIComponent("Übungsblatt 3 – Seite 1.pdf")}`, { method: "PUT", headers: { ...H, "content-type": "application/pdf" }, body: pdf });
await fetch(`${BASE}/api/outbox/chatgpt/fremd.png`, { method: "PUT", headers: { ...H, "content-type": "image/png" }, body: png });
res = await call("notizbuch_ausgang_liste", {});
let list = JSON.parse(txt(res));
ok(Array.isArray(list) && list.length === 2 && list.some((f) => f.name === name), "Liste: nur der Ordner claude", list);
res = await call("notizbuch_ausgang_holen", { name });
const img = res.content?.find((c) => c.type === "image");
ok(img?.mimeType === "image/png" && Buffer.from(img.data, "base64").equals(png), "PNG kommt als Bild", res);
res = await call("notizbuch_ausgang_holen", { name: "Übungsblatt 3 – Seite 1.pdf" });
const emb = res.content?.find((c) => c.type === "resource");
ok(emb?.resource?.mimeType === "application/pdf" && Buffer.from(emb.resource.blob, "base64").equals(pdf), "PDF als eingebettete Datei", res);
res = await call("notizbuch_ausgang_holen", { name: "fremd.png" });
ok(res.isError, "Datei aus dem Ordner chatgpt nicht erreichbar");
res = await call("notizbuch_ausgang_holen", { name: "../chatgpt/fremd.png" });
ok(res.isError, "auch nicht über ../");
for (const bad of ["..", "."]) {
  res = await call("notizbuch_ausgang_holen", { name: bad });
  ok(res.isError && !/chatgpt/.test(JSON.stringify(res)), `Name "${bad}" verrät keine anderen Ausgänge`, res);
}
const big = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.from(Array.from({ length: 1200000 }, (_, i) => (i * 7919) & 255))]);
await fetch(`${BASE}/api/outbox/claude/gross.png`, { method: "PUT", headers: { ...H, "content-type": "image/png" }, body: big });
res = await call("notizbuch_ausgang_holen", { name: "gross.png" });
ok(Buffer.from(res.content?.[0]?.data || "", "base64").equals(big), "1,2-MB-PNG kommt unverändert an");
await call("notizbuch_ausgang_loeschen", { name: "gross.png" });
const bigPdf = Buffer.concat([pdf, Buffer.from(Array.from({ length: 900000 }, (_, i) => (i * 31) & 255))]);
res = await call("notizbuch_pdf_senden", { title: "Groß", pdf_base64: bigPdf.toString("base64") });
const gp = (await (await fetch(`${BASE}/api/library`, { headers: H })).json()).docs.find((d) => d.title === "Groß");
ok(!res.isError && Buffer.from(await (await fetch(`${BASE}/api/pdf/${gp?.id}`, { headers: H })).arrayBuffer()).equals(bigPdf), "900-KB-PDF über base64 unverändert");
res = await call("notizbuch_ausgang_loeschen", { name });
ok(!res.isError, "löschen");
list = JSON.parse(txt(await call("notizbuch_ausgang_liste", {})));
ok(list.length === 1 && list[0].name.endsWith(".pdf"), "danach nur noch das PDF");
const cg = await (await fetch(`${BASE}/api/outbox/chatgpt`, { headers: H })).json();
ok(cg.files.length === 1, "Ordner chatgpt unberührt");
await call("notizbuch_ausgang_loeschen", { name: "Übungsblatt 3 – Seite 1.pdf" });
ok(txt(await call("notizbuch_ausgang_liste", {})) === "Der Ausgang ist leer.", "leerer Ausgang");

console.log("Lernwörter");
res = await call("notizbuch_lernwoerter_ablegen", { add: [{ wort: "Fahrrad", satz: "Ich fahre mit dem Fahrrad." }, { wort: "Meer" }] });
ok(JSON.parse(txt(res)).abgelegt?.length === 2, "zwei Wörter abgelegt", res);
res = await call("notizbuch_lernwoerter_ablegen", { remove: ["Meer"] });
ok(JSON.parse(txt(res)).entfernt?.[0] === "Meer", "eines entfernt");
res = await call("notizbuch_lernwoerter_ablegen", { add: Array.from({ length: 501 }, () => ({ wort: "Fahrrad" })) });
ok(res.isError && /500/.test(txt(res)), "mehr als 500 auf einmal → Fehler");
const direct = await fetch(`${BASE}/api/lernen/woerter`, { method: "POST", headers: { ...H, "content-type": "application/json" }, body: JSON.stringify({ remove: Array(501).fill("x") }) });
ok(direct.status === 400, "auch über /api: mehr als 500 → 400");
res = await call("notizbuch_lernwoerter_ablegen", { add: [{ wort: "Meer", satz: "Das Meer ist blau." }] });
ok(JSON.parse(txt(res)).abgelegt?.[0] === "Meer", "entferntes Wort kommt mit add zurück");
res = await call("notizbuch_lernwoerter_ablegen", { remove: ["Meer"] });
res = await call("notizbuch_lernwoerter_ablegen", {});
ok(res.isError, "ohne add/remove → Fehler");
const st = JSON.parse(txt(await call("notizbuch_lernstand", {})));
ok(st.woerter.some((w) => w.wort === "Fahrrad" && w.satz) && !st.woerter.some((w) => w.wort === "Meer"), "Lernstand ohne entfernte Wörter", st);

console.log(`\n${passes} ok, ${failures} fehlgeschlagen`);
process.exit(failures ? 1 : 0);
