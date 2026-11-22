// Mios Lernkarten: Anki-Stapel importieren, "20 Karten lernen", die App wählt die sinnvollsten Karten.
// Kein Tageslimit, keine "fällig"-Zahlen: Mio entscheidet selbst, wie viel er lernt.
"use strict";

// ================= Speicher (IndexedDB, nur auf diesem Gerät) =================
const DB = (() => {
  let dbp = null;
  const open = () => dbp || (dbp = new Promise((res, rej) => {
    const r = indexedDB.open("mio-karten", 1);
    r.onupgradeneeded = () => {
      const d = r.result;
      d.createObjectStore("cards", { keyPath: "id" });
      d.createObjectStore("media", { keyPath: "name" });
      d.createObjectStore("styles", { keyPath: "nt" });
    };
    r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error);
  }));
  const tx = async (store, mode, fn) => {
    const d = await open();
    return new Promise((res, rej) => {
      const t = d.transaction(store, mode); const s = t.objectStore(store);
      let out; const r = fn(s); if (r) r.onsuccess = () => { out = r.result; };
      t.oncomplete = () => res(out); t.onerror = () => rej(t.error); t.onabort = () => rej(t.error);
    });
  };
  return {
    all: store => tx(store, "readonly", s => s.getAll()),
    get: (store, key) => tx(store, "readonly", s => s.get(key)),
    put: (store, val) => tx(store, "readwrite", s => s.put(val)),
    putMany: (store, vals) => tx(store, "readwrite", s => { vals.forEach(v => s.put(v)); }),
    delMany: (store, keys) => tx(store, "readwrite", s => { keys.forEach(k => s.delete(k)); }),
  };
})();

// ================= Lernlogik (FSRS-4.5, vereinfacht) =================
// s = Stabilität in Tagen (nach s Tagen weiß man die Karte noch mit 90 % Wahrscheinlichkeit)
// d = Schwierigkeit 1..10, last = Zeitpunkt der letzten Wiederholung
const W = [0.4872, 1.4003, 3.7145, 13.8206, 5.1618, 1.2298, 0.8975, 0.031, 1.6474, 0.1367, 1.0461, 2.1072, 0.0793, 0.3246, 1.587, 0.2272, 2.8755];
const F = 19 / 81, DECAY = -0.5, TARGET = 0.9;
const clampD = d => Math.min(10, Math.max(1, d));
const D0 = g => clampD(W[4] - (g - 3) * W[5]);

function recall(c, now = Date.now()) {
  if (!c.sched) return null;
  const t = Math.max(0, (now - c.sched.last) / 864e5);
  return Math.pow(1 + F * t / c.sched.s, DECAY);
}

// g: 1 = nicht gewusst, 2 = mit Mühe, 3 = gewusst, 4 = ganz leicht
function schedule(c, g, now = Date.now()) {
  const old = c.sched;
  if (!old) { c.sched = { s: W[g - 1], d: D0(g), last: now, reps: 1, lapses: g === 1 ? 1 : 0 }; return; }
  const R = recall(c, now), { s: S, d: D } = old;
  let s;
  if (g === 1) s = Math.min(S, W[11] * Math.pow(D, -W[12]) * (Math.pow(S + 1, W[13]) - 1) * Math.exp(W[14] * (1 - R)));
  else s = S * (Math.exp(W[8]) * (11 - D) * Math.pow(S, -W[9]) * (Math.exp(W[10] * (1 - R)) - 1) * (g === 2 ? W[15] : 1) * (g === 4 ? W[16] : 1) + 1);
  const d = clampD(W[7] * D0(3) + (1 - W[7]) * (D - W[6] * (g - 3)));
  c.sched = { s: Math.max(0.1, s), d, last: now, reps: old.reps + 1, lapses: old.lapses + (g === 1 ? 1 : 0) };
}

// Die n sinnvollsten Karten: zuerst Karten, die man gerade zu vergessen beginnt (am meisten gefährdete zuerst),
// dann neue Karten, dann die, deren Wiederholung als Nächstes ansteht. Es gibt immer Karten, nie "fertig".
function pickCards(pool, n, now = Date.now()) {
  const due = [], soon = [], fresh = [];
  for (const c of pool) {
    const r = recall(c, now);
    if (r === null) fresh.push(c); else if (r < TARGET) due.push([r, c]); else soon.push([r, c]);
  }
  due.sort((a, b) => a[0] - b[0]); soon.sort((a, b) => a[0] - b[0]);
  fresh.sort((a, b) => a.order - b.order);
  // Auch wenn viel zu wiederholen ist, kommen ein paar neue Karten dazu (macht mehr Spaß).
  const newShare = due.length >= n ? Math.min(fresh.length, Math.ceil(n * 0.2)) : 0;
  const order = [...due.slice(0, n - newShare).map(x => x[1]), ...fresh, ...soon.map(x => x[1]), ...due.slice(n - newShare).map(x => x[1])];
  const rev = [], neu = [], notes = new Set(), later = [];
  // Geschwister (z. B. dog→Hund und Hund→dog) möglichst nicht in derselben Runde
  for (const c of order) {
    if (rev.length + neu.length >= n) break;
    if (notes.has(c.note)) { later.push(c); continue; }
    notes.add(c.note); (c.sched ? rev : neu).push(c);
  }
  for (const c of later) { if (rev.length + neu.length >= n) break; (c.sched ? rev : neu).push(c); }
  // Neue Karten gleichmäßig zwischen die Wiederholungen streuen
  const out = []; const total = rev.length + neu.length;
  let ni = 0, ri = 0;
  for (let k = 0; k < total; k++) {
    const wantNew = neu.length && (ni + 1) / neu.length <= (k + 1) / total + 1e-9;
    if ((wantNew && ni < neu.length) || ri >= rev.length) out.push(neu[ni++]); else out.push(rev[ri++]);
  }
  return out;
}

// ================= Zustand =================
const S = { cards: [], styles: {}, view: "home", sel: new Set(), count: 20, session: null, busy: null };
const store = {
  get(k, d) { try { const v = localStorage.getItem("mio-karten:" + k); return v === null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem("mio-karten:" + k, JSON.stringify(v)); } catch {} },
};
S.sel = new Set(store.get("sel", []));
S.count = store.get("count", 20);

const $ = (sel, root = document) => root.querySelector(sel);
const esc = s => String(s).replace(/[&<>"]/g, ch => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[ch]));
const app = () => $("#app");

async function load() {
  S.cards = await DB.all("cards");
  S.styles = Object.fromEntries((await DB.all("styles")).map(x => [x.nt, x.css]));
  const names = new Set(S.cards.map(c => c.deck));
  for (const s of [...S.sel]) if (![...names].some(n => n === s || n.startsWith(s + "::"))) S.sel.delete(s);
}

// ================= Stapel-Baum =================
function deckTree() {
  const counts = {};
  for (const c of S.cards) {
    const parts = c.deck.split("::");
    for (let i = 1; i <= parts.length; i++) {
      const k = parts.slice(0, i).join("::");
      const x = counts[k] || (counts[k] = { n: 0, known: 0 });
      x.n++; if (c.sched && c.sched.s >= 7) x.known++;
    }
  }
  return Object.keys(counts).sort((a, b) => a.localeCompare(b, "de")).map(k => ({ name: k, depth: k.split("::").length - 1, ...counts[k] }));
}
const inSel = deck => [...S.sel].some(s => deck === s || deck.startsWith(s + "::"));
const poolCards = () => (S.sel.size ? S.cards.filter(c => inSel(c.deck)) : S.cards);

// ================= Startseite =================
function home() {
  S.view = "home";
  const tree = deckTree();
  const pool = poolCards();
  const learned = S.cards.filter(c => c.sched).length;
  app().innerHTML = `
  <div class="home">
    <header class="hd"><h1>Lernkarten</h1><button class="icon" id="menu" aria-label="Einstellungen">⋯</button></header>
    ${tree.length ? `
      <p class="sub">${S.sel.size ? "Tippe Stapel an, um sie dazu- oder wegzunehmen." : "Tippe einen Stapel an, um nur aus ihm zu lernen."}</p>
      <ul class="decks">${tree.map(d => {
        const on = S.sel.has(d.name), parentOn = !on && inSel(d.name);
        const short = d.name.split("::").pop();
        const pct = d.n ? Math.round(100 * d.known / d.n) : 0;
        return `<li><button class="deck ${on ? "on" : ""} ${parentOn ? "inherit" : ""}" data-deck="${esc(d.name)}" style="--depth:${d.depth}">
          <span class="tick">${on || parentOn ? "✓" : ""}</span>
          <span class="dn">${esc(short)}</span>
          <span class="meta">${d.n} Karten</span>
          <span class="bar" title="sicher gewusst"><i style="width:${pct}%"></i></span>
        </button></li>`; }).join("")}</ul>
      <div class="go">
        <div class="counts">${[10, 20, 30, 50].map(n => `<button class="cnt ${S.count === n ? "on" : ""}" data-n="${n}">${n}</button>`).join("")}</div>
        <button class="big" id="start" ${pool.length ? "" : "disabled"}>${S.count} Karten lernen</button>
        <p class="hint">${S.sel.size ? `aus ${S.sel.size === 1 ? "„" + esc([...S.sel][0].split("::").pop()) + "“" : S.sel.size + " Stapeln"}` : "aus allen Stapeln"}${learned ? ` · ${learned} Karten schon kennengelernt` : ""}</p>
      </div>` : `
      <div class="empty">
        <p>Noch keine Karten da.</p>
        <p class="sub">Füge einen Anki-Stapel hinzu (eine <b>.apkg</b>-Datei, z. B. von AnkiWeb oder von deiner Lehrerin).</p>
      </div>`}
    <div class="add">
      ${Foto.homeHTML()}
      <label class="addbtn">＋ Anki-Stapel hinzufügen<input type="file" id="file" hidden></label>
    </div>
  </div>`;
  app().querySelectorAll(".deck").forEach(b => b.onclick = () => toggleDeck(b.dataset.deck));
  app().querySelectorAll(".cnt").forEach(b => b.onclick = () => { S.count = +b.dataset.n; store.set("count", S.count); home(); });
  const st = $("#start"); if (st) st.onclick = () => startSession();
  $("#file").onchange = e => { const f = e.target.files[0]; e.target.value = ""; if (f) doImport(f); };
  $("#menu").onclick = settings;
  Foto.wireHome();
}

function toggleDeck(name) {
  if (S.sel.has(name)) S.sel.delete(name);
  else {
    // Untergeordnete Auswahl ist im neuen Stapel enthalten
    for (const s of [...S.sel]) if (s.startsWith(name + "::")) S.sel.delete(s);
    if (inSel(name)) { /* schon über Überstapel gewählt: nichts tun */ } else S.sel.add(name);
  }
  store.set("sel", [...S.sel]); home();
}

// ================= Import =================
async function doImport(file) {
  overlay("Stapel wird geladen …");
  try {
    const res = await Anki.importFile(file, msg => overlay(msg));
    overlay("Wird gespeichert …");
    const old = new Map(S.cards.map(c => [c.id, c]));
    let added = 0, updated = 0;
    const base = Date.now() * 1000; // neue Karten: spätere Stapel kommen nach früheren dran
    const cards = res.cards.map(c => {
      const prev = old.get(c.id);
      if (prev) { updated++; return { ...c, order: prev.order, sched: prev.sched || c.sched }; } // Lernstand behalten
      added++; return { ...c, order: base + c.order };
    });
    await DB.putMany("cards", cards);
    await DB.putMany("styles", Object.entries(res.styles).map(([nt, css]) => ({ nt, css })));
    for (let i = 0; i < res.media.length; i += 50) await DB.putMany("media", res.media.slice(i, i + 50));
    try { navigator.storage && navigator.storage.persist && navigator.storage.persist(); } catch {}
    await load();
    overlay(null);
    home();
    toast(added && updated ? `${added} neue Karten, ${updated} aktualisiert` : added ? `${added} Karten hinzugefügt` : `${updated} Karten aktualisiert`);
  } catch (e) {
    console.error(e); overlay(null); home();
    toast("Das hat nicht geklappt: " + (e && e.message ? e.message : e), 6000);
  }
}

// ================= Lernen =================
function startSession() {
  const picked = pickCards(poolCards(), S.count);
  if (!picked.length) return;
  S.session = { queue: picked.map(c => ({ c, tries: 0 })), total: picked.length, done: 0, first: {}, step: 0 };
  S.view = "learn"; showCard();
}

const mediaUrls = new Map();
async function mediaUrl(name) {
  if (mediaUrls.has(name)) return mediaUrls.get(name);
  const m = await DB.get("media", name);
  const u = m ? URL.createObjectURL(m.blob) : null;
  mediaUrls.set(name, u); return u;
}

async function fillCard(host, html, nt) {
  const root = host.shadowRoot || host.attachShadow({ mode: "open" });
  html = html.replace(/\[sound:([^\]]+)\]/g, (a, f) => `<button class="snd" data-snd="${esc(f)}" aria-label="Anhören">🔊</button>`);
  // Bilder erst nach dem Einsetzen aus dem Gerätespeicher laden (sonst fragt der Browser den Server danach)
  html = html.replace(/(<img\b[^>]*?\s)src=(["']?)([^"'\s>]*)\2/gi, (a, pre, q, src) =>
    /^(https?:|data:|blob:)/.test(src) ? a : `${pre}data-m="${esc(src)}"`);
  root.innerHTML = `<style>${S.styles[nt] || ""}</style><style>${CARD_CSS}</style><div class="card">${html}</div>`;
  root.querySelectorAll("script").forEach(s => s.remove());
  for (const img of root.querySelectorAll("img[data-m]")) {
    const src = img.getAttribute("data-m");
    let name = src; try { name = decodeURIComponent(src); } catch {}
    const u = await mediaUrl(name); if (u) img.src = u;
  }
  const sounds = [...root.querySelectorAll(".snd")];
  for (const b of sounds) b.onclick = async e => { e.stopPropagation(); play(b.dataset.snd); };
  for (const b of root.querySelectorAll(".tts")) b.onclick = e => { e.stopPropagation(); speak(b.dataset.t, b.dataset.lang); };
  return sounds.map(b => b.dataset.snd);
}
const CARD_CSS = `
  :host { display:block; }
  .card { font-size: 26px; line-height: 1.35; text-align: center; color: #23302a; background: transparent !important; padding: 0; overflow-wrap: anywhere; }
  img { max-width: 100%; height: auto; max-height: 40vh; }
  hr#answer { border: 0; border-top: 2px dashed #d8d0bf; margin: 18px 0; }
  .cloze { font-weight: 700; color: #1f6fd1; }
  .snd { font-size: 22px; border: 1px solid #e0d8c6; background: #fff; border-radius: 22px; width: 44px; height: 44px; cursor: pointer; vertical-align: middle; }
  .typed { font-weight: 700; color: #1f6fd1; }
  details.hint summary { color: #1f6fd1; cursor: pointer; font-size: 18px; }
  ul, ol { text-align: left; display: inline-block; }
  .dir { font-size: 13px; color: #8a8f88; text-transform: uppercase; letter-spacing: .5px; margin-bottom: 14px; }
  .w { font-size: 30px; font-weight: 600; }
  .s { font-size: 19px; font-style: italic; color: #4c5a52; margin-top: 12px; }
  .tts { font-size: 16px; border: 1px solid #e0d8c6; background: #fff; border-radius: 16px; width: 32px; height: 32px; cursor: pointer; vertical-align: middle; margin-left: 6px; font-style: normal; }
`;
function speak(text, lang) {
  try {
    speechSynthesis.cancel();
    const u = new SpeechSynthesisUtterance(text); u.lang = lang; u.rate = 0.9;
    const v = speechSynthesis.getVoices().find(v => v.lang.replace("_", "-") === lang) || speechSynthesis.getVoices().find(v => v.lang.startsWith(lang.slice(0, 2)));
    if (v) u.voice = v;
    speechSynthesis.speak(u);
  } catch {}
}
let audio = null;
async function play(name) {
  const u = await mediaUrl(name); if (!u) return;
  try { if (audio) audio.pause(); audio = new Audio(u); await audio.play(); } catch {}
}

async function showCard() {
  const ss = S.session; const item = ss.queue[0];
  if (!item) return finish();
  ss.revealed = false;
  app().innerHTML = `
  <div class="learn">
    <header class="hd">
      <button class="icon" id="quit" aria-label="Beenden">✕</button>
      <div class="prog"><i style="width:${100 * ss.done / ss.total}%"></i></div>
      <span class="pn">${ss.done} / ${ss.total}</span>
    </header>
    <div class="deckname">${esc(item.c.deck.split("::").pop())}${item.tries ? ` · <span class="again">nochmal</span>` : ""}${!item.c.sched && !item.tries ? ` · <span class="neu">neu</span>` : ""}</div>
    <div class="cardbox" id="box"><div id="face"></div></div>
    <div class="actions" id="act"><button class="big" id="flip">Umdrehen</button></div>
  </div>`;
  $("#quit").onclick = () => { S.session = null; home(); };
  $("#box").onclick = () => { if (!ss.revealed) reveal(); };
  $("#flip").onclick = reveal;
  const snds = await fillCard($("#face"), item.c.q, item.c.nt);
  if (snds.length) play(snds[0]);
}

async function reveal() {
  const ss = S.session; const item = ss.queue[0]; if (ss.revealed) return;
  ss.revealed = true;
  const snds = await fillCard($("#face"), item.c.a, item.c.nt);
  $("#box").classList.add("open");
  const qs = (item.c.q.match(/\[sound:[^\]]+\]/g) || []).length;
  if (snds.length > qs) play(snds[qs]);
  $("#act").innerHTML = `
    <button class="rate r1" data-g="1"><b>Nicht gewusst</b></button>
    <button class="rate r2" data-g="2"><b>Mit Mühe</b></button>
    <button class="rate r3" data-g="3"><b>Gewusst</b></button>
    <button class="rate r4" data-g="4"><b>Ganz leicht</b></button>`;
  app().querySelectorAll(".rate").forEach(b => b.onclick = () => rate(+b.dataset.g));
}

async function rate(g) {
  const ss = S.session; const item = ss.queue.shift(); const c = item.c;
  if (!(c.id in ss.first)) {
    ss.first[c.id] = g;
    schedule(c, g);
    DB.put("cards", c);
    const day = new Date().toISOString().slice(0, 10); const log = store.get("log", {});
    log[day] = (log[day] || 0) + 1; store.set("log", log);
  }
  if (g === 1 && item.tries < 3) {
    // Kommt in dieser Runde nochmal, nach ein paar anderen Karten
    item.tries++;
    ss.queue.splice(Math.min(ss.queue.length, 3 + Math.floor(Math.random() * 2)), 0, item);
  } else ss.done++;
  showCard();
}

function finish() {
  S.view = "done";
  const ss = S.session; const vals = Object.values(ss.first);
  const right = vals.filter(g => g >= 3).length;
  const day = new Date().toISOString().slice(0, 10); const today = store.get("log", {})[day] || 0;
  const lines = ["Super gemacht!", "Stark!", "Geschafft!", "Sehr gut!"];
  app().innerHTML = `
  <div class="done">
    <div class="star">★</div>
    <h1>${lines[Math.floor(Math.random() * lines.length)]}</h1>
    <p>${ss.total} Karten, davon <b>${right}</b> gleich gewusst.</p>
    ${today > ss.total ? `<p class="sub">Heute schon ${today} Karten gelernt.</p>` : ""}
    <button class="big" id="more">Noch ${S.count} Karten</button>
    <button class="ghost" id="back">Zurück</button>
  </div>`;
  S.session = null;
  $("#more").onclick = startSession;
  $("#back").onclick = home;
}

// ================= Einstellungen =================
function settings() {
  const tree = deckTree().filter(d => d.depth === 0);
  sheet(`
    <h2>Einstellungen</h2>
    <h3>Stapel entfernen</h3>
    ${tree.length ? tree.map(d => `<button class="row" data-del="${esc(d.name)}">${esc(d.name)} <span>${d.n} Karten · entfernen</span></button>`).join("") : `<p class="sub">Keine Stapel.</p>`}
    ${Foto.settingsHTML()}
    <h3>Lernstand</h3>
    <p class="sub">Der Lernstand ist nur auf diesem Gerät gespeichert. Eine Sicherung kannst du z. B. in „Dateien“ ablegen.</p>
    <button class="row" id="exp">Lernstand sichern</button>
    <label class="row">Lernstand zurückholen<input type="file" id="imp" hidden></label>
  `, root => {
    Foto.wireSettings(root);
    root.querySelectorAll("[data-del]").forEach(b => b.onclick = async () => {
      const name = b.dataset.del;
      if (b.dataset.sure !== "1") { b.dataset.sure = "1"; b.querySelector("span").textContent = "Wirklich? Nochmal tippen"; b.classList.add("warn"); return; }
      const ids = S.cards.filter(c => c.deck === name || c.deck.startsWith(name + "::")).map(c => c.id);
      await DB.delMany("cards", ids); await load(); closeSheet(); home(); toast(`„${name}“ entfernt`);
    });
    $("#exp", root).onclick = () => {
      const data = { app: "mio-karten", v: 1, at: new Date().toISOString(), sched: Object.fromEntries(S.cards.filter(c => c.sched).map(c => [c.id, c.sched])), log: store.get("log", {}) };
      const a = document.createElement("a");
      a.href = URL.createObjectURL(new Blob([JSON.stringify(data)], { type: "application/json" }));
      a.download = `Lernstand-${data.at.slice(0, 10)}.json`; document.body.appendChild(a); a.click(); a.remove();
    };
    $("#imp", root).onchange = async e => {
      const f = e.target.files[0]; if (!f) return;
      try {
        const data = JSON.parse(await f.text()); if (data.app !== "mio-karten") throw new Error("keine Sicherung dieser App");
        let n = 0; const changed = [];
        for (const c of S.cards) { const s = data.sched[c.id]; if (s && (!c.sched || s.last > c.sched.last)) { c.sched = s; changed.push(c); n++; } }
        await DB.putMany("cards", changed); closeSheet(); home(); toast(`${n} Karten übernommen`);
      } catch (err) { toast("Konnte die Sicherung nicht lesen: " + err.message, 5000); }
    };
  });
}

// ================= Kleinteile =================
function overlay(msg) {
  let o = $("#ov");
  if (!msg) { if (o) o.remove(); return; }
  if (!o) { o = document.createElement("div"); o.id = "ov"; o.className = "ov"; document.body.appendChild(o); }
  o.innerHTML = `<div class="ovbox"><div class="spin"></div><p>${esc(msg)}</p></div>`;
}
let toastT = 0;
function toast(msg, ms = 3000) {
  let t = $("#toast"); if (!t) { t = document.createElement("div"); t.id = "toast"; t.className = "toast"; document.body.appendChild(t); }
  t.textContent = msg; t.classList.add("on"); clearTimeout(toastT); toastT = setTimeout(() => t.classList.remove("on"), ms);
}
function sheet(html, init) {
  closeSheet();
  const s = document.createElement("div"); s.id = "sheet"; s.className = "sheetbg";
  s.innerHTML = `<div class="sheet"><button class="icon close" aria-label="Schließen">✕</button>${html}</div>`;
  s.onclick = e => { if (e.target === s) closeSheet(); };
  document.body.appendChild(s); $(".close", s).onclick = closeSheet; init && init(s);
}
function closeSheet() { const s = $("#sheet"); if (s) s.remove(); }

document.addEventListener("keydown", e => {
  if (S.view !== "learn" || !S.session) return;
  if (!S.session.revealed && (e.key === " " || e.key === "Enter")) { e.preventDefault(); reveal(); }
  else if (S.session.revealed && /^[1-4]$/.test(e.key)) rate(+e.key);
});

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("sw.js").catch(() => {});
  // Neue Version: auf der Startseite neu laden
  const hadController = !!navigator.serviceWorker.controller; // beim allerersten Start nicht neu laden
  navigator.serviceWorker.addEventListener("controllerchange", () => { if (hadController && S.view === "home" && !$("#sheet")) location.reload(); });
}

load().then(home).catch(e => { app().textContent = "Fehler beim Laden: " + e; });
