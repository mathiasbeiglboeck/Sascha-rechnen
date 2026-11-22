// Vokabelfotos: Mio fotografiert eine Vokabelliste, Claude am Mac von Papa macht daraus Karten in beide Richtungen.
// Weg: Foto → Notizbuch-Server (eigener Lernkarten-Schlüssel) → Helfer am Mac → Antwort (JSON) → hier Vorschau → Karten.
"use strict";

const Foto = (() => {
  const cfg = () => store.get("foto", null); // {u: Server, k: Lernkarten-Schlüssel}
  const pending = () => store.get("fotos", []); // [{id, t, status, note, answer?}]
  const savePending = list => store.set("fotos", list);

  // Einrichtungslink oder nur der Code dahinter
  function setup(text) {
    const m = String(text || "").match(/foto=([A-Za-z0-9_-]+)/) || String(text || "").trim().match(/^([A-Za-z0-9_-]{20,})$/);
    if (!m) return false;
    try {
      const b64 = m[1].replace(/-/g, "+").replace(/_/g, "/");
      const o = JSON.parse(decodeURIComponent(escape(atob(b64))));
      if (!/^https:\/\/[^/]+$/.test(o.u) && !/^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(o.u)) return false;
      if (!o.k || o.k.length < 20) return false;
      store.set("foto", { u: o.u, k: o.k }); return true;
    } catch { return false; }
  }
  // Link direkt in diesem Browser geöffnet
  if (/#foto=/.test(location.hash)) {
    const ok = setup(location.hash);
    history.replaceState(null, "", location.pathname + location.search);
    if (ok) setTimeout(() => toast("Vokabelfotos sind eingerichtet"), 400);
  }

  async function call(method, path, body) {
    const c = cfg(); if (!c) throw new Error("nicht eingerichtet");
    const r = await fetch(c.u + path, { method, body, headers: { Authorization: "Bearer " + c.k } });
    const data = await r.json().catch(() => ({}));
    if (!r.ok) { const e = new Error(data.error || "Fehler " + r.status); e.status = r.status; throw e; }
    return data;
  }

  // Foto verkleinern (und HEIC zu JPEG): lange Seite höchstens 2200 Pixel
  async function shrink(file) {
    const url = URL.createObjectURL(file);
    try {
      const img = await new Promise((res, rej) => { const i = new Image(); i.onload = () => res(i); i.onerror = () => rej(new Error("Bild lässt sich nicht öffnen")); i.src = url; });
      const k = Math.min(1, 2200 / Math.max(img.naturalWidth, img.naturalHeight));
      const c = document.createElement("canvas");
      c.width = Math.round(img.naturalWidth * k); c.height = Math.round(img.naturalHeight * k);
      c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
      return await new Promise(res => c.toBlob(res, "image/jpeg", 0.85));
    } finally { URL.revokeObjectURL(url); }
  }

  async function send(file) {
    overlay("Foto wird geschickt …");
    try {
      const jpg = await shrink(file);
      const id = crypto.randomUUID().toUpperCase();
      const f = new FormData();
      f.append("meta", JSON.stringify({ from: "Lernkarten" }));
      f.append("foto", jpg, "foto.jpg");
      const list = pending(); list.push({ id, t: Date.now(), status: "sending" }); savePending(list);
      await call("POST", `/api/karten/foto/${id}`, f);
      update(id, { status: "open" });
      overlay(null); home(); toast("Claude liest jetzt deine Vokabeln");
      poll();
    } catch (e) {
      overlay(null);
      savePending(pending().filter(p => p.status !== "sending"));
      home(); toast("Das Foto ist nicht angekommen: " + e.message, 6000);
    }
  }
  const update = (id, patch) => savePending(pending().map(p => (p.id === id ? { ...p, ...patch } : p)));

  let timer = 0;
  async function poll() {
    clearTimeout(timer);
    const open = pending().filter(p => p.status === "open" || p.status === "claimed");
    if (!open.length || document.hidden) return;
    let changed = false;
    for (const p of open) {
      try {
        const r = await call("GET", `/api/karten/foto/${p.id}`);
        if (r.status !== p.status || r.note !== p.note) { update(p.id, { status: r.status, note: r.note || null, answer: r.answer || null }); changed = true; }
      } catch (e) {
        if (e.status === 404) { update(p.id, { status: "failed", note: "Das Foto ist am Server verschwunden." }); changed = true; }
      }
    }
    if (changed && S.view === "home" && !$("#sheet")) home();
    timer = setTimeout(poll, 3000);
  }
  document.addEventListener("visibilitychange", () => { if (!document.hidden) poll(); });

  // Startseite: Knöpfe und laufende Fotos
  function homeHTML() {
    if (!cfg()) return "";
    const items = pending().map(p => {
      const age = (Date.now() - p.t) / 1000;
      let txt, cls = "", act = "";
      if (p.status === "answered") {
        let n = 0; try { n = JSON.parse(p.answer).karten.length; } catch {}
        txt = n ? `<b>${n} Vokabeln erkannt</b> · ansehen` : "<b>Keine Vokabeln erkannt</b> · ansehen"; cls = "ready"; act = "view";
      } else if (p.status === "failed") { txt = `Hat nicht geklappt${p.note ? ": " + esc(p.note) : ""}`; cls = "bad"; act = "drop"; }
      else if (p.status === "claimed") txt = `<span class="spin s"></span> Claude liest deine Vokabeln …`;
      else if (p.note) txt = `<span class="spin s"></span> ${esc(p.note)}`;
      else txt = `<span class="spin s"></span> ${age > 45 ? "Wartet auf den Mac …" : "Foto ist angekommen …"}`;
      return `<button class="fotoitem ${cls}" data-id="${p.id}" data-act="${act}">${txt}${act === "drop" ? ' <span class="x">entfernen</span>' : ""}</button>`;
    }).join("");
    return `${items}
      <label class="addbtn cam">📷 Vokabeln fotografieren<input type="file" accept="image/*" capture="environment" id="cam" hidden></label>
      <label class="link">oder ein Foto auswählen<input type="file" accept="image/*" id="pick" hidden></label>`;
  }
  function wireHome() {
    for (const sel of ["#cam", "#pick"]) {
      const inp = $(sel); if (inp) inp.onchange = e => { const f = e.target.files[0]; e.target.value = ""; if (f) send(f); };
    }
    app().querySelectorAll(".fotoitem").forEach(b => b.onclick = () => {
      const p = pending().find(x => x.id === b.dataset.id); if (!p) return;
      if (b.dataset.act === "view") review(p);
      if (b.dataset.act === "drop") { drop(p.id); home(); }
    });
    poll();
  }
  function drop(id) {
    savePending(pending().filter(p => p.id !== id));
    call("DELETE", `/api/karten/foto/${id}`).catch(() => {});
  }

  const LANG = { englisch: "en-GB", französisch: "fr-FR", franzoesisch: "fr-FR", spanisch: "es-ES", italienisch: "it-IT" };

  // Vorschau: Mio sieht die erkannten Vokabeln, kann sie ausbessern oder weglassen, und fügt sie hinzu
  function review(p) {
    let ans; try { ans = JSON.parse(p.answer); } catch { ans = { karten: [] }; }
    const sprache = ans.sprache || "Englisch";
    const date = new Date(p.t).toLocaleDateString("de-AT", { day: "numeric", month: "numeric" });
    const deck = `${sprache}::${ans.titel || "Foto vom " + date}`;
    S.view = "review";
    app().innerHTML = `
    <div class="review">
      <header class="hd"><button class="icon" id="back" aria-label="Zurück">←</button><h1>Vokabeln</h1></header>
      ${ans.karten.length ? `
      <label class="field">Stapel<input id="deck" value="${esc(deck)}"></label>
      <p class="sub">Tippe in ein Feld, um es auszubessern. Mit ✕ lässt du eine Vokabel weg.</p>
      <ul class="voks">${ans.karten.map((k, i) => `
        <li data-i="${i}">
          <div class="vrow"><input class="vf" value="${esc(k.fremd)}" aria-label="${esc(sprache)}"><input class="vd" value="${esc(k.deutsch)}" aria-label="Deutsch">
            <button class="vx" aria-label="Weglassen">✕</button></div>
          <textarea class="vs" rows="2" aria-label="Beispielsatz">${esc(k.satz || "")}</textarea>
          ${k.satzSelbst ? `<div class="vnote">Beispielsatz von Claude</div>` : ""}
          ${k.verbessert ? `<div class="vnote warn">Ausgebessert, im Foto stand: „${esc(k.verbessert)}“</div>` : ""}
        </li>`).join("")}</ul>
      <div class="go"><button class="big" id="add">Hinzufügen</button>
        <button class="ghost" id="del">Foto verwerfen</button></div>` : `
      <div class="empty"><p>Keine Vokabeln erkannt.</p><p class="sub">${esc(ans.problem || "Versuch es mit einem schärferen Foto, auf dem die ganze Liste gut zu sehen ist.")}</p>
        <button class="big" id="del">Verstanden</button></div>`}
    </div>`;
    const count = () => { const n = app().querySelectorAll(".voks li:not(.off)").length; const b = $("#add"); if (b) { b.textContent = `${n} Vokabeln hinzufügen (${2 * n} Karten)`; b.disabled = !n; } };
    count();
    app().querySelectorAll(".vx").forEach(b => b.onclick = () => { b.closest("li").classList.toggle("off"); count(); });
    $("#back").onclick = home;
    $("#del").onclick = () => { drop(p.id); home(); };
    const add = $("#add");
    if (add) add.onclick = async () => {
      const deckName = ($("#deck").value || deck).split("::").map(s => s.trim()).filter(Boolean).join("::") || deck;
      const lang = LANG[sprache.toLowerCase()] || "";
      const cards = []; const base = Date.now() * 1000;
      app().querySelectorAll(".voks li:not(.off)").forEach((li, n) => {
        const fremd = $(".vf", li).value.trim(), deutsch = $(".vd", li).value.trim(), satz = $(".vs", li).value.trim();
        if (!fremd || !deutsch) return;
        const note = `foto-${p.id}-${li.dataset.i}`;
        const say = t => (lang ? ` <button class="tts" data-lang="${lang}" data-t="${esc(t)}" aria-label="Vorlesen">🔊</button>` : "");
        const F = `<div class="w">${esc(fremd)}${say(fremd)}</div>`;
        const Sz = satz ? `<div class="s">${esc(satz)}${say(satz)}</div>` : "";
        const D = `<div class="w">${esc(deutsch)}</div>`;
        const dir = (a, b) => `<div class="dir">${a} → ${b}</div>`;
        cards.push({ id: note + ":0", note, deck: deckName, nt: "foto", order: base + 2 * n,
          q: dir(esc(sprache), "Deutsch") + F + Sz, a: dir(esc(sprache), "Deutsch") + F + Sz + `<hr id="answer">` + D });
        cards.push({ id: note + ":1", note, deck: deckName, nt: "foto", order: base + 2 * n + 1,
          q: dir("Deutsch", esc(sprache)) + D, a: dir("Deutsch", esc(sprache)) + D + `<hr id="answer">` + F + Sz });
      });
      const old = new Map(S.cards.map(c => [c.id, c]));
      await DB.putMany("cards", cards.map(c => (old.get(c.id) ? { ...c, sched: old.get(c.id).sched, order: old.get(c.id).order } : c)));
      drop(p.id); await load();
      S.sel = new Set([deckName]); store.set("sel", [...S.sel]);
      home(); toast(`${cards.length} Karten in „${deckName.split("::").pop()}“`);
    };
  }

  // Einstellungen
  function settingsHTML() {
    return `<h3>Vokabelfotos</h3>${cfg()
      ? `<p class="sub">Eingerichtet. Fotos gehen an Claude am Mac.</p><button class="row" id="fotooff">Vokabelfotos ausschalten</button>`
      : `<p class="sub">Füge hier den Einrichtungslink von Papa ein.</p>
         <div class="vrow"><input id="fotolink" placeholder="Link einsetzen"><button class="row small" id="fotoon">OK</button></div>`}`;
  }
  function wireSettings(root) {
    const on = $("#fotoon", root), off = $("#fotooff", root);
    if (on) on.onclick = () => { if (setup($("#fotolink", root).value)) { closeSheet(); home(); toast("Vokabelfotos sind eingerichtet"); } else toast("Der Link passt nicht", 4000); };
    if (off) off.onclick = () => { if (off.dataset.sure !== "1") { off.dataset.sure = "1"; off.textContent = "Wirklich ausschalten? Nochmal tippen"; return; } store.set("foto", null); closeSheet(); home(); };
  }

  return { homeHTML, wireHome, settingsHTML, wireSettings };
})();
