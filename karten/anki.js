// Anki-Import: liest .apkg/.colpkg (alte und neue Formate) und baut daraus fertige Karten.
// Ergebnis: { decks:[name], cards:[{id, deck, q, a, nt, order, sched?}], styles:{nt:css}, media:[{name, blob}] }
"use strict";

const Anki = (() => {
  let sqlPromise = null;
  const sql = () => sqlPromise || (sqlPromise = initSqlJs({ locateFile: f => "lib/" + f }));

  // ---------- kleiner Protobuf-Leser (nur was wir brauchen) ----------
  function pb(bytes) {
    const out = {}; let i = 0;
    const varint = () => { let r = 0, m = 1, b; do { b = bytes[i++]; r += (b & 127) * m; m *= 128; } while (b & 128); return r; };
    while (i < bytes.length) {
      const key = varint(), f = Math.floor(key / 8), t = key & 7; let v;
      if (t === 0) v = varint();
      else if (t === 2) { const n = varint(); v = bytes.subarray(i, i + n); i += n; }
      else if (t === 1) { i += 8; continue; }
      else if (t === 5) { i += 4; continue; }
      else break;
      (out[f] = out[f] || []).push(v);
    }
    return out;
  }
  const txt = b => (b ? new TextDecoder().decode(b) : "");
  const isZstd = b => b && b[0] === 0x28 && b[1] === 0xb5 && b[2] === 0x2f && b[3] === 0xfd;
  const unz = b => (isZstd(b) ? fzstd.decompress(b) : b);

  function rows(db, q) {
    const res = db.exec(q); if (!res.length) return [];
    const { columns, values } = res[0];
    return values.map(v => Object.fromEntries(columns.map((c, k) => [c, v[k]])));
  }

  // Die neue Anki-Datenbank verwendet eine eigene Sortierung ("unicase"), die sql.js nicht kennt.
  // Wir entfernen sie aus dem Schema und öffnen die Datenbank neu.
  function openDb(SQL, bytes) {
    let db = new SQL.Database(bytes);
    const bad = rows(db, "select count(*) n from sqlite_master where sql like '%unicase%'")[0].n;
    if (bad) {
      db.exec("PRAGMA writable_schema=ON");
      db.exec("UPDATE sqlite_master SET sql=replace(sql,'COLLATE unicase','') WHERE sql LIKE '%unicase%'");
      db.exec("PRAGMA writable_schema=OFF");
      const data = db.export(); db.close();
      db = new SQL.Database(data);
    }
    return db;
  }

  // ---------- Notiztypen ----------
  function noteTypes(db) {
    const tables = new Set(rows(db, "select name from sqlite_master where type='table'").map(r => r.name));
    const nts = {};
    if (tables.has("notetypes")) {
      for (const r of rows(db, "select id, name, config from notetypes")) {
        const c = pb(r.config);
        nts[r.id] = { name: r.name, cloze: (c[1] || [0])[0] === 1, css: txt((c[3] || [])[0]), flds: [], tmpls: [] };
      }
      for (const r of rows(db, "select ntid, ord, name from fields order by ntid, ord"))
        if (nts[r.ntid]) nts[r.ntid].flds[r.ord] = r.name;
      for (const r of rows(db, "select ntid, ord, name, config from templates order by ntid, ord")) {
        const c = pb(r.config);
        if (nts[r.ntid]) nts[r.ntid].tmpls[r.ord] = { name: r.name, q: txt((c[1] || [])[0]), a: txt((c[2] || [])[0]) };
      }
    } else {
      const models = JSON.parse(rows(db, "select models from col")[0].models || "{}");
      for (const [id, m] of Object.entries(models)) {
        nts[id] = { name: m.name, cloze: m.type === 1, css: m.css || "", flds: [], tmpls: [] };
        for (const f of m.flds) nts[id].flds[f.ord] = f.name;
        for (const t of m.tmpls) nts[id].tmpls[t.ord] = { name: t.name, q: t.qfmt, a: t.afmt };
      }
    }
    return nts;
  }

  function deckNames(db) {
    const tables = new Set(rows(db, "select name from sqlite_master where type='table'").map(r => r.name));
    const out = {};
    if (tables.has("decks")) for (const r of rows(db, "select id, name from decks")) out[r.id] = r.name.split("\x1f").join("::");
    else for (const [id, d] of Object.entries(JSON.parse(rows(db, "select decks from col")[0].decks || "{}"))) out[id] = d.name;
    return out;
  }

  // ---------- Vorlagen ausfüllen ----------
  const strip = h => h.replace(/<[^>]*>/g, "").replace(/&nbsp;/g, " ").trim();

  function clozeNums(text) {
    const s = new Set(); const re = /\{\{c(\d+)::/g; let m;
    while ((m = re.exec(text))) s.add(+m[1]);
    return s;
  }
  function cloze(text, n, answer) {
    // Lücken ohne Verschachtelung: {{c1::Text::Hinweis}}
    return text.replace(/\{\{c(\d+)::([\s\S]*?)(?:::([\s\S]*?))?\}\}/g, (all, k, body, hint) => {
      if (+k !== n) return body;
      if (answer) return `<span class="cloze">${body}</span>`;
      return `<span class="cloze">[${hint ? hint : "…"}]</span>`;
    });
  }

  function applyFilters(name, fields, ctx) {
    const parts = name.split(":"); const fname = parts.pop().trim(); const filters = parts.map(s => s.trim());
    let v;
    if (fname === "FrontSide") v = ctx.front || "";
    else if (fname === "Tags") v = ctx.tags || "";
    else if (fname === "Deck") v = ctx.deck || "";
    else if (fname === "Subdeck") v = (ctx.deck || "").split("::").pop();
    else if (fname === "Type") v = ctx.ntName || "";
    else if (fname === "Card") v = ctx.tmplName || "";
    else if (fname in fields) v = fields[fname];
    else return "";
    for (const f of filters.reverse()) {
      if (f === "text") v = strip(v);
      else if (f === "cloze") v = cloze(v, ctx.ord + 1, ctx.answer);
      else if (f === "type") v = ctx.answer ? `<div class="typed">${v}</div>` : "";
      else if (f === "hint") v = v ? `<details class="hint"><summary>Hinweis</summary>${v}</details>` : "";
      else if (/^(furigana|kana|kanji)$/.test(f)) v = v.replace(/\[[^\]]*\]/g, f === "kana" ? "" : "");
      else if (f.startsWith("tts")) v = "";
    }
    return v;
  }

  function nonEmpty(name, fields, ctx) {
    const m = /^c(\d+)$/.exec(name);
    if (m && ctx.clozeField !== undefined) return clozeNums(fields[ctx.clozeField] || "").has(+m[1]);
    return strip(fields[name] || "").length > 0 || /<img|\[sound:/.test(fields[name] || "");
  }

  function render(tmpl, fields, ctx) {
    // Abschnitte {{#Feld}}…{{/Feld}} und {{^Feld}}…{{/Feld}} (verschachtelt)
    const sec = /\{\{([#^])\s*([^}]+?)\s*\}\}([\s\S]*?)\{\{\/\s*\2\s*\}\}/;
    let s = tmpl, guard = 0, m;
    while ((m = sec.exec(s)) && guard++ < 500) {
      const show = nonEmpty(m[2], fields, ctx) === (m[1] === "#");
      s = s.slice(0, m.index) + (show ? m[3] : "") + s.slice(m.index + m[0].length);
    }
    s = s.replace(/\{\{\s*([^#^/{][^}]*?)\s*\}\}/g, (all, name) => applyFilters(name, fields, ctx));
    return s;
  }

  // ---------- Medien ----------
  async function readMedia(zip) {
    const mf = zip.file("media"); if (!mf) return [];
    const raw = await mf.async("uint8array");
    let list = [];
    const dec = unz(raw);
    const asText = txt(dec).trim();
    if (asText.startsWith("{")) {
      list = Object.entries(JSON.parse(asText)).map(([zipName, name]) => ({ zipName, name }));
    } else {
      const top = pb(dec);
      (top[1] || []).forEach((e, idx) => {
        const x = pb(e); const name = txt((x[1] || [])[0]);
        const legacy = x[255] ? txt(x[255][0]) : null;
        if (name) list.push({ zipName: legacy || String(idx), name });
      });
    }
    const out = [];
    for (const { zipName, name } of list) {
      const f = zip.file(zipName); if (!f) continue;
      const data = unz(await f.async("uint8array"));
      out.push({ name, blob: new Blob([data], { type: mime(name) }) });
    }
    return out;
  }
  function mime(n) {
    const e = (n.split(".").pop() || "").toLowerCase();
    return { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif", webp: "image/webp", svg: "image/svg+xml",
      mp3: "audio/mpeg", m4a: "audio/mp4", ogg: "audio/ogg", oga: "audio/ogg", wav: "audio/wav", opus: "audio/ogg", webm: "audio/webm", mp4: "video/mp4" }[e] || "application/octet-stream";
  }

  // ---------- Hauptfunktion ----------
  async function importFile(file, progress = () => {}) {
    progress("Datei wird geöffnet …");
    const zip = await JSZip.loadAsync(file);
    const pick = ["collection.anki21b", "collection.anki21", "collection.anki2"].find(n => zip.file(n));
    if (!pick) throw new Error("Das ist keine Anki-Datei (.apkg).");
    let bytes = await zip.file(pick).async("uint8array");
    if (pick.endsWith("b")) bytes = fzstd.decompress(bytes);
    const SQL = await sql();
    progress("Karten werden gelesen …");
    const db = openDb(SQL, bytes);
    const nts = noteTypes(db), decks = deckNames(db);
    const colRow = rows(db, "select crt from col")[0] || {};
    const crt = colRow.crt || 0;
    const notes = {};
    for (const n of rows(db, "select id, guid, mid, flds, tags from notes")) notes[n.id] = n;
    const cards = [], usedDecks = new Set();
    const list = rows(db, "select id, nid, did, odid, ord, type, queue, due, odue, ivl, factor, lapses, reps from cards order by did, due, nid, ord");
    const now = Date.now();
    list.forEach((c, idx) => {
      const n = notes[c.nid]; const nt = n && nts[n.mid]; if (!nt) return;
      const vals = n.flds.split("\x1f"); const fields = {};
      nt.flds.forEach((name, k) => { if (name != null) fields[name] = vals[k] || ""; });
      const tmpl = nt.cloze ? nt.tmpls[0] : nt.tmpls[c.ord]; if (!tmpl) return;
      const deck = decks[c.odid || c.did] || decks[c.did] || "Stapel";
      const ctx = { ord: c.ord, tags: (n.tags || "").trim(), deck, ntName: nt.name, tmplName: tmpl.name,
        clozeField: nt.cloze ? nt.flds.find(f => /\{\{c\d+::/.test(fields[f] || "")) : undefined };
      const q = render(tmpl.q, fields, { ...ctx, answer: false });
      const a = render(tmpl.a, fields, { ...ctx, answer: true, front: render(tmpl.q, fields, { ...ctx, answer: false, front: "" }) });
      if (!strip(q) && !/<img|\[sound:/.test(q)) return; // leere Karte
      usedDecks.add(deck);
      const card = { id: `${n.guid}:${c.ord}`, deck, q, a, nt: String(n.mid), note: n.guid, order: idx };
      // Lernstand aus Anki übernehmen, falls mitexportiert
      if (c.type === 2 && c.ivl > 0 && crt) {
        const dueMs = (crt + (c.odid ? c.odue : c.due) * 86400) * 1000;
        card.sched = { s: c.ivl, d: Math.min(10, Math.max(1, 11 - (c.factor || 2500) / 250)), last: Math.min(now, dueMs - c.ivl * 864e5), reps: c.reps || 1, lapses: c.lapses || 0 };
      }
      cards.push(card);
    });
    db.close();
    progress("Bilder und Töne …");
    const media = await readMedia(zip);
    const styles = {}; for (const [id, nt] of Object.entries(nts)) styles[id] = nt.css;
    return { decks: [...usedDecks], cards, styles, media };
  }

  return { importFile, _render: render, _cloze: cloze };
})();
