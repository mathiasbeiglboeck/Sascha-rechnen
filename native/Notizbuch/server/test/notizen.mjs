// Test für „Claude schreiben lassen“ (Notizen im Dokument) gegen einen lokalen Server mit Wegwerf-Schlüssel:
//   cd native/Notizbuch/server && npx wrangler dev --ip 127.0.0.1 --port 8791 --var SECRET:testkey --persist-to <leerer Ordner>
//   BASE=http://127.0.0.1:8791 KEY=testkey node test/notizen.mjs
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
  else { failures++; console.log("  FAIL", msg, extra !== undefined ? JSON.stringify(extra).slice(0, 600) : ""); }
};
const uuid = () => crypto.randomUUID().toUpperCase();

async function api(method, path, { json } = {}) {
  const h = { ...H };
  let b;
  if (json !== undefined) { b = JSON.stringify(json); h["content-type"] = "application/json"; }
  const r = await fetch(BASE + path, { method, headers: h, body: b });
  const ct = r.headers.get("content-type") || "";
  const text = await r.text();
  return { status: r.status, data: ct.includes("json") ? JSON.parse(text) : text, text };
}

const PNG = () => { const b = new Uint8Array(200); b.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]); return b; };
const JPG = () => { const b = new Uint8Array(300); b.set([0xff, 0xd8, 0xff, 0xe0]); return b; };

function createAsk(doc, id, meta) {
  const f = new FormData();
  f.append("meta", JSON.stringify(meta));
  f.append("question", new Blob([PNG()], { type: "image/png" }), "question.png");
  f.append("page", new Blob([JPG()], { type: "image/jpeg" }), "page.jpg");
  return fetch(`${BASE}/api/doc/${doc}/asks/${id}`, { method: "PUT", headers: H, body: f })
    .then(async (r) => ({ status: r.status, data: await r.json() }));
}

async function newDoc(pageCount = 4) {
  const id = uuid(), now = Date.now() / 1000;
  await api("PUT", `/api/library/${id}`, { json: { id, title: "Notizen-Test", kind: "notebook", created: now, modified: now, pageCount, pagesVersion: 0 } });
  return id;
}

const anchor = { page: 1, x: 100, y: 200, w: 150, h: 40 };

async function answer(id, body) {
  const c = await api("POST", `/api/asks/${id}/claim`, { json: { lease: 900 } });
  const r = await api("PUT", `/api/asks/${id}/answer`, { json: { claim: c.data.claim, ...body } });
  return { claim: c.data, r };
}

// Für die Abschnitte zu Seitenänderungen: Stelle auf einer Seite, Notiz, Frage holen, Seiten ihrer Notizen
const spot = (page) => ({ page, x: 100, y: 200, w: 150, h: 40 });
const note = (page, text, extra = {}) => ({ page, x: 0.1, y: 0.2, w: 0.5, text, ...extra });
const askOf = async (doc, id) => (await api("GET", `/api/doc/${doc}/asks`)).data.asks.find((a) => a.id === id);
const notePages = (a) => (a?.notes || []).map((n) => n.page);
async function writeAsk(doc, page, pv) {
  const id = uuid();
  await createAsk(doc, id, { anchor: spot(page), pv, effort: "quick", created: 1, from: "iPad", mode: "write" });
  return id;
}
const claimAsk = async (id) => (await api("POST", `/api/asks/${id}/claim`, { json: { lease: 900 } })).data;
const answerWith = (id, claim, notes, markdown = "Erledigt.") =>
  api("PUT", `/api/asks/${id}/answer`, { json: { claim, markdown, notes } });
const moveAsks = (doc, body) => api("PATCH", `/api/doc/${doc}/asks`, { json: body });

async function main() {
  const doc = await newDoc();
  console.log("== Schreib-Modus");
  const w = uuid(), q = uuid();
  let r = await createAsk(doc, w, { anchor, pv: 0, effort: "thorough", created: 1, from: "iPad", mode: "write" });
  ok(r.status === 200 && r.data.asks.find((a) => a.id === w)?.mode === "write", "mode write kommt an", r.data);
  r = await createAsk(doc, q, { anchor, pv: 0, effort: "quick", created: 2, from: "iPad", mode: "quatsch" });
  ok(r.status === 200 && !("mode" in r.data.asks.find((a) => a.id === q)), "unbekannter mode fällt weg", r.data);

  const notes = [
    { page: 1, x: 0.82, y: 0.3, w: 0.16, text: "Vorzeichen! $-2$", color: "red", size: "small", box: [0.1, 0.28, 0.5, 0.33] },
    { page: 0, x: 0.1, y: 0.5, w: 0.8, text: "**Lösung:** $\\int_0^1 x\\,dx = \\tfrac12$" },
    { page: 2, x: 2, y: 0.5, w: 0.5, text: "außerhalb" },
    { page: 1, x: 0.1, y: 0.1, w: 0.5, text: "x", color: "pink", size: "riesig", extra: 1 },
    { page: -1, x: 0.1, y: 0.1, w: 0.5, text: "Seite -1 gibt es beim Antworten nicht" },
    { page: 1, x: 0.1, y: 0.1, w: 0.5, text: "   " },
  ];
  let a = await answer(w, { markdown: "Zwei Notizen gesetzt.", notes });
  ok(a.claim.mode === "write", "claim nennt mode", a.claim);
  ok(a.r.status === 200, "Antwort mit Notizen 200", a.r);
  r = await api("GET", `/api/doc/${doc}/asks`);
  let got = r.data.asks.find((x) => x.id === w);
  ok(got.status === "answered" && got.answer === "Zwei Notizen gesetzt.", "beantwortet", got);
  ok(Array.isArray(got.notes) && got.notes.length === 3, "ungültige Notizen fallen weg (3 bleiben)", got.notes);
  ok(got.notes[0].color === "red" && got.notes[0].size === "small" && got.notes[0].box.length === 4, "Farbe, Größe, Kasten bleiben", got.notes[0]);
  ok(!("color" in got.notes[2]) && !("size" in got.notes[2]) && !("extra" in got.notes[2]), "unbekannte Farbe/Größe/Felder fallen weg", got.notes[2]);

  a = await answer(q, { markdown: "Normale Antwort", notes });
  r = await api("GET", `/api/doc/${doc}/asks`);
  got = r.data.asks.find((x) => x.id === q);
  ok(got.status === "answered" && !("notes" in got), "Notizen nur bei mode write", got);

  console.log("== Notizen verschieben (Seitenänderung, Löschen einer Notiz)");
  // Wie die App: die Notizen des Servers, mit neuen Seiten oder ohne die gelöschten
  const before = (await api("GET", `/api/doc/${doc}/asks`)).data.asks.find((x) => x.id === w).notes;
  const moved = [{ ...before[0], page: 2 }, { ...before[1], page: -1 }];
  r = await api("PATCH", `/api/doc/${doc}/asks`, { json: { pv: 5, anchors: { [w]: { ...anchor, page: 2 } }, notes: { [w]: moved, [q]: moved } } });
  got = r.data.asks.find((x) => x.id === w);
  ok(r.status === 200 && got.pv === 5 && got.anchor.page === 2 && got.notes.length === 2 && got.notes[0].page === 2 && got.notes[1].page === -1, "Notizen verschoben, eine entfernt, Seite −1 erlaubt", got);
  ok(!("notes" in r.data.asks.find((x) => x.id === q)), "Fragen ohne mode write bekommen keine Notizen", r.data);
  r = await api("PATCH", `/api/doc/${doc}/asks`, { json: { pv: 3, notes: { [w]: [{ ...before[0], page: 0 }] } } });
  got = r.data.asks.find((x) => x.id === w);
  ok(got.notes.length === 1 && got.notes[0].page === 2, "älterer Seitenstand: nur das Entfernen wirkt, die Seiten bleiben", got);
  r = await api("PATCH", `/api/doc/${doc}/asks`, { json: { pv: 5, notes: { [w]: [{ ...before[0], page: 2 }, { page: 1, x: 0.1, y: 0.1, w: 0.5, text: "neu" }] } } });
  got = r.data.asks.find((x) => x.id === w);
  ok(got.notes.length === 1 && got.notes[0].text === before[0].text, "Geräte fügen keine Notizen hinzu, Entferntes kommt nicht wieder", got);
  r = await api("PATCH", `/api/doc/${doc}/asks`, { json: { pv: 5, notes: { [w]: [] } } });
  got = r.data.asks.find((x) => x.id === w);
  ok(got.notes.length === 0 && got.v > 0, "letzte Notiz gelöscht", got);

  // Ein eigenes Dokument (8 Seiten) für die Seitenstände der folgenden Abschnitte
  const wdoc = await newDoc(8);
  console.log("== Seiten geändert, während Claude schreibt (claimPv)");
  {
    const x = await writeAsk(wdoc, 2, 0);
    await new Promise((res) => setTimeout(res, 1200));
    const c = await claimAsk(x);
    const c1age = c.age;
    await moveAsks(wdoc, { pv: 1, anchors: { [x]: spot(3) } }); // eine Seite davor eingefügt
    let r = await answerWith(x, c.claim, [note(2, "a"), note(3, "b")]);
    ok(r.status === 409 && r.data.code === "pages-changed", "Antwort mit Notizen nach Seitenänderung: 409 pages-changed", r);
    let g = await askOf(wdoc, x);
    ok(g.status === "open" && /Seiten/.test(g.note || "") && g.anchor.page === 3 && g.pv === 1 && !g.notes, "wieder offen, mit Hinweis, Stelle neu, ohne Notizen", g);
    const open = (await api("GET", "/api/asks/open")).data;
    ok(open.asks.some((a) => a.id === x), "sofort wieder dran für den Helfer", open);
    ok((await api("GET", `/api/asks/${x}/question`)).status === 200, "Bilder bleiben für den zweiten Lauf");
    const c2 = await claimAsk(x);
    ok(c2.pv === 1 && c2.anchor.page === 3, "zweiter Lauf mit neuem Seitenstand", c2);
    ok(c1age >= 1 && c2.age < 0.8, "neuer Lauf zählt ab dem Neustellen (arrived), wartet also wie eine neue Frage aufs PDF", { c1age, age: c2.age });
    r = await answerWith(x, c2.claim, [note(3, "a"), note(4, "b")]);
    g = await askOf(wdoc, x);
    ok(r.status === 200 && g.status === "answered" && notePages(g).join() === "3,4" && g.answer === "Erledigt.", "zweite Antwort gilt unverändert", g);
  }
  {
    const x = await writeAsk(wdoc, 2, 1);
    let page = 2, pv = 1, last;
    for (let i = 0; i < 3; i++) {
      const c = await claimAsk(x);
      pv += 1; page += 1;
      await moveAsks(wdoc, { pv, anchors: { [x]: spot(page) } });
      last = await answerWith(x, c.claim, [note(page - 1, "auf der Seite der Frage"), note(page + 2, "anderswo")]);
    }
    const g = await askOf(wdoc, x);
    ok(last.status === 200 && notePages(g).join() === "5" && g.notes[0].text === "auf der Seite der Frage" && /Eine Notiz fehlt/.test(g.answer),
      "nach zwei neuen Läufen: nur die Notizen auf der Seite der Frage, mit Hinweis", g);
  }
  {
    const x = await writeAsk(wdoc, 2, 10);
    const c = await claimAsk(x);
    await moveAsks(wdoc, { pv: 11, anchors: { [x]: spot(-1) } }); // Seite der Frage gelöscht
    const r = await answerWith(x, c.claim, [note(2, "a"), note(4, "b")]);
    const g = await askOf(wdoc, x);
    ok(r.status === 200 && g.status === "answered" && notePages(g).length === 0 && /2 Notizen fehlen/.test(g.answer), "Seite der Frage gelöscht: ohne Notizen, mit Hinweis", g);
  }
  {
    const x = await writeAsk(wdoc, 2, 15);
    const c = await claimAsk(x);
    await moveAsks(wdoc, { pv: 16, anchors: { [x]: spot(3) } });
    const r = await answerWith(x, c.claim, [note(2, "unter dem Auftrag"), note(2, "noch eine", { y: 0.6 })]);
    const g = await askOf(wdoc, x);
    ok(r.status === 200 && g.status === "answered" && notePages(g).join() === "3,3" && g.answer === "Erledigt.",
      "alle Notizen auf der Seite der Frage: gleich gespeichert, mit ihr gerückt, ohne Hinweis und ohne neuen Lauf", g);
  }
  {
    const x = await writeAsk(wdoc, 1, 20);
    const c = await claimAsk(x);
    await moveAsks(wdoc, { pv: 21, anchors: { [x]: spot(2) } });
    const r = await answerWith(x, c.claim, []);
    const g = await askOf(wdoc, x);
    ok(r.status === 200 && g.status === "answered", "ohne Notizen (Claude schrieb nichts): gilt trotz Seitenänderung", g);
  }

  console.log("== Verschoben von einem Gerät, das die Notizen nicht kannte");
  {
    const x = await writeAsk(wdoc, 2, 30);
    const c = await claimAsk(x);
    await answerWith(x, c.claim, [note(2, "auf der Seite der Frage"), note(5, "weiter hinten")]);
    let r = await moveAsks(wdoc, { pv: 31, anchors: { [x]: spot(3) }, notesUnknown: [x] });
    let g = r.data.asks.find((a) => a.id === x);
    ok(notePages(g).join() === "3" && g.notes[0].text === "auf der Seite der Frage" && /Eine Notiz fehlt/.test(g.answer),
      "neue App kannte die Notizen nicht (notesUnknown): Notizen der Seite der Frage rücken mit, die übrigen fallen weg (Hinweis)", g);
    r = await moveAsks(wdoc, { pv: 31, anchors: { [x]: spot(3) }, notesUnknown: [x] });
    g = r.data.asks.find((a) => a.id === x);
    ok(notePages(g).join() === "3" && (g.answer.match(/fehlt/g) || []).length === 1, "Wiederholung (gleicher Seitenstand) ändert nichts", g);
  }
  {
    const x = await writeAsk(wdoc, 2, 40);
    const c = await claimAsk(x);
    await answerWith(x, c.claim, [note(2, "a"), note(5, "b")]);
    const r = await moveAsks(wdoc, { pv: 41, anchors: { [x]: spot(3) } });
    const g = r.data.asks.find((a) => a.id === x);
    ok(notePages(g).join() === "2,5" && g.anchor.page === 3 && g.answer === "Erledigt.", "nicht in notesUnknown: Notizen unverändert (Gerät kennt sie, Seiten gleich)", g);
  }
  {
    const x = await writeAsk(wdoc, 2, 50);
    const c = await claimAsk(x);
    await answerWith(x, c.claim, [note(2, "a"), note(5, "b")]);
    const r = await moveAsks(wdoc, { pv: 51, anchors: { [x]: spot(-1) }, notesUnknown: [x] });
    const g = r.data.asks.find((a) => a.id === x);
    ok(notePages(g).length === 0 && g.anchor.page === -1 && /2 Notizen fehlen/.test(g.answer), "Seite der Frage gelöscht (Gerät kannte die Notizen nicht): alle weg, Hinweis", g);
  }
  {
    const x = await writeAsk(wdoc, 2, 55);
    const c = await claimAsk(x);
    await answerWith(x, c.claim, [note(2, "a"), note(5, "b")]);
    const r = await moveAsks(wdoc, { pv: 56, anchors: { [x]: spot(3) } });
    const g = r.data.asks.find((a) => a.id === x);
    ok(notePages(g).join() === "2,5" && g.anchor.page === 3 && g.pv === 56 && g.answer === "Erledigt.",
      "ältere App (154/162, ohne notesUnknown): Notizen bleiben, wie sie sind (wie bisher)", g);
  }

  console.log("== Notizen zusammenführen (Löschen gewinnt, nichts kommt wieder)");
  {
    const x = await writeAsk(wdoc, 1, 60);
    const c = await claimAsk(x);
    const na = note(1, "A"), nb = note(2, "B"), nc = note(3, "C", { color: "red", box: [0.1, 0.1, 0.2, 0.2] });
    await answerWith(x, c.claim, [na, nb, nc]);
    let r = await moveAsks(wdoc, { pv: 62, anchors: { [x]: spot(2) }, notes: { [x]: [{ ...na, page: 2 }, { ...nb, page: 3 }, { ...nc, page: 4 }] } });
    let g = r.data.asks.find((a) => a.id === x);
    ok(notePages(g).join() === "2,3,4", "neuerer Seitenstand: Seiten des Geräts gelten", g);
    r = await moveAsks(wdoc, { pv: 61, notes: { [x]: [{ ...nb, page: 2 }, { ...nc, page: 3 }] } });
    g = r.data.asks.find((a) => a.id === x);
    ok(g.notes.map((n) => n.text).join() === "B,C" && notePages(g).join() === "3,4", "älterer Seitenstand: Löschen wirkt, Seiten bleiben", g);
    r = await moveAsks(wdoc, { pv: 63, anchors: { [x]: spot(3) }, notes: { [x]: [{ ...na, page: 3 }, { ...nb, page: 4 }, { ...nc, page: 5 }] } });
    g = r.data.asks.find((a) => a.id === x);
    ok(g.notes.map((n) => n.text).join() === "B,C" && notePages(g).join() === "4,5", "neuerer Seitenstand bringt Gelöschtes nicht zurück", g);
    r = await moveAsks(wdoc, { pv: 63, notes: { [x]: [{ ...nb, page: 4 }, { ...nc, page: 5 }, note(1, "neu")] } });
    g = r.data.asks.find((a) => a.id === x);
    ok(g.notes.map((n) => n.text).join() === "B,C", "Geräte fügen keine Notizen hinzu", g);
    r = await moveAsks(wdoc, { pv: 63, notes: { [x]: [{ ...nb, page: 4 }, { ...nc, page: -1 }] } });
    g = r.data.asks.find((a) => a.id === x);
    ok(notePages(g).join() === "4,-1", "Seite −1 (geparkt) bleibt erlaubt", g);
    const v0 = g.v;
    r = await moveAsks(wdoc, { pv: 63, notes: { [x]: [{ ...nb, page: 4 }, { ...nc, page: -1 }] } });
    g = r.data.asks.find((a) => a.id === x);
    ok(g.v === v0, "unveränderte Notizen schreiben nichts", { v0, v: g.v });
    // Neuerer Seitenstand ohne gültige Stelle: Die Frage bleibt auf ihrem Seitenstand, also gelten die Seiten des Geräts nicht
    r = await moveAsks(wdoc, { pv: 64, notes: { [x]: [{ ...nb, page: 9 }] } });
    g = r.data.asks.find((a) => a.id === x);
    ok(g.notes.map((n) => n.text).join() === "B" && notePages(g).join() === "4" && g.pv === 63,
      "neuerer Seitenstand ohne Stelle: Löschen wirkt, Seiten und Seitenstand bleiben", g);
  }

  console.log("== Halbe Zeichenpaare");
  {
    const x = await writeAsk(wdoc, 1, 70);
    const c = await claimAsk(x);
    await answerWith(x, c.claim, [note(1, "a".repeat(7999) + "\u{1D465}")]);
    const r = await api("GET", `/api/doc/${wdoc}/asks`);
    const g = r.data.asks.find((a) => a.id === x);
    ok(g.notes[0].text.length === 7999 && !/\\ud8[0-9a-f]{2}"/i.test(r.text), "Notiz an einem Zeichenpaar gekürzt: kein halbes am Ende", { len: g.notes[0].text.length });
  }
  {
    const x = await writeAsk(wdoc, 1, 80);
    let c = await claimAsk(x);
    await api("PUT", `/api/asks/${x}/answer`, { json: { claim: c.claim, release: true, note: "b".repeat(299) + "\u{1F600}" } });
    let r = await api("GET", `/api/doc/${wdoc}/asks`);
    let g = r.data.asks.find((a) => a.id === x);
    ok(g.note.length === 299 && !/\\ud83d"/i.test(r.text), "Hinweis beim Zurückgeben an einem Zeichenpaar gekürzt", { len: g.note.length });
    c = await claimAsk(x);
    await api("PUT", `/api/asks/${x}/answer`, { json: { claim: c.claim, error: "e".repeat(1999) + "\u{1F600}" } });
    r = await api("GET", `/api/doc/${wdoc}/asks`);
    g = r.data.asks.find((a) => a.id === x);
    ok(g.status === "failed" && g.note.length === 1999 && !/\\ud83d"/i.test(r.text), "Fehlertext an einem Zeichenpaar gekürzt", { len: g.note.length });
  }

  for (const d of [doc, wdoc]) {
    for (const x of (await api("GET", `/api/doc/${d}/asks`)).data.asks) await api("DELETE", `/api/doc/${d}/asks/${x.id}`);
  }
  console.log(`\n${passes} passed, ${failures} failed`);
  process.exit(failures ? 1 : 0);
}
main().catch((e) => { console.error(e); process.exit(2); });
