# Mac test: „Claude schreiben lassen“ follow-up (server + helper 167, app 168)

Branch `claude/link-vorschau`. Batch = `70bdd64..29dfdae`: `2131281` = server + helper (167), `29dfdae` = app (168).
This file was added on top as 169 and changes no code, so a build of 169 is the batch (the app then shows 169).
In the field: app 162 (`0bdd588`, bundle id `de.beiglboeck.notizbuch.R5W5PMUZKF`) on the iPhone, the iPad mini and
the iPad Pro. The iPad Pro also has app 154 (`eaaf6f9`, the first write mode from the other project, bundle id
`de.beiglboeck.notizbuch`); its asks and notes code (Ask.swift, SyncEngine.swift, NotesOverlay.swift,
NoteTypesetter.swift) is identical to 162, so everything said about 162 here holds for 154 too. Live server and
helper = `0bdd588` (its helfer.mjs is byte-identical to 70bdd64). The server deploy also carries ee0ef7c (Lernwörter
limits, ".." blocked in the connector's outbox).

Labels: F1–F11 are the review findings on the app, SH-F1 the one on server and helper; each step says what it checks.
Known limits that stay (the steps name them as residuals):
- Residual 1: on 162 and 154, deleting the question page still deletes the whole ask with its notes (S1c).
- Residual 3: race B, a page change that crosses an answer the device has not seen yet. Notes off the question's page
  are dropped, and the answer says so (S8b).
- Residual 4: the question page is deleted while Claude writes. The answer comes without notes and says so; Undo does
  not bring them back (S3).
- Residual 9: between the server deploy and einrichten.sh, an old helper re-runs a refused write ask in the same chat
  (S7). The notes still end up right.

## Already verified on Linux (do not repeat)

- Suites, each on a fresh local wrangler: asks 134/0, notizen 40/0, strokes 93/0, markdown 52/0, karten 22/0,
  lernen 23/0, mcp 59/0, export 213/0, helper-test 305/0, weitere-test 268/0, and the old helper-test (0bdd588)
  against the new server 272/0.
- JS models of the app logic 90/90 (plus a mutation run), typesetter model 16/16.
- Old helper (0bdd588) against the new server, fake Claude, 12/12 as the design predicts: a normal question is
  answered as before; a write ask with a page inserted while Claude writes and notes on two pages gets 409
  `pages-changed`; the old helper logs it as „inzwischen neu vergeben“ followed by a misleading „beantwortet nach …“,
  re-runs in the SAME chat (`--resume`) with „die ganze Seite 3“, and the notes end up right ([2,3] at the new pv);
  with all notes on the question's page the answer is stored at once, no re-run.
- Not verified anywhere yet: the Swift compiles (no toolchain on Linux). 2.1 is the first compile.

## 0. Rules (as in earlier rounds)

- Load check first: read the last 300 lines of `~/Library/Application Support/BetterNotes-Helfer/helfer.log` (read
  only). Lernwort lines in the last 10 minutes: Sascha is practising. Do not boot simulators or run xcodebuild; check
  again every 5 minutes, at most 30 minutes.
- Work only in `~/Documents/ClaudeCode/notizbuch-v3`. Install nothing. Put
  `~/Documents/ClaudeCode/Sascha/.notizbuch-tools/node-v22.23.4-darwin-arm64/bin` first in PATH.
- Never open notizbuch-zugang.txt or any config.json of his helper. Never print or use the real server key. Never
  contact `*.workers.dev`. Do not run notizbuch-server-aktualisieren.sh, notizbuch-einrichten.sh or
  claude-fragen/einrichten.sh.
- Do not touch Mathias' documents, his Claude Code settings or his helper (label `local.betternotes.claude-fragen`).
  Never run the real `claude`: the test helper uses `test/fake-claude`.
- Simulators, throwaway notebooks and local servers only. No pushes, no commits. If something needs a code change,
  report the exact error text and propose a minimal diff.
- Part 4 (real devices): Mathias deploys and tests. The session installs the app by cable only when its instructions
  say so (R0 step 2), and reads helfer.log, read only.

## 1. Where each device check runs

| Device check | Finding | Simulator, local wrangler | Real devices |
|---|---|---|---|
| Delete the question page of a write ask with notes elsewhere, Rückgängig, delete again and close the overview; second device 162 and new | app F2 (with F1, F6) | Yes, fully: S1 (B new, then B 162), plus S2 and S5 for the neighbouring paths | R2 once. Needs only the cable install (works before or after the deploy). The 154 app watches, like 162 |
| Insert a page above a write ask while Claude works (thorough), a note on another page: the bubble waits, the answer arrives once, notes in place | SH-F1 (case A) | Yes, with fake Claude: S4a (notebook), S4c (PDF) | R1a after the deploy (server and helper 2131281), real Claude |
| Same with all notes under the question: answer on time | SH-F1 | Yes: S4b | R1b after the deploy |
| Background while long answers are typeset, back after a minute: text appears | app F8 (retry) | Emulated only: S6e kills the simulator's WebContent while the app is in the background | R3 (real iOS behaviour), after the cable install |
| Share a page right after opening a document with notes: text present | app F8 (export waits), F10 | Yes: S6a, S6b | R4 after the cable install |
| Ask Claude right after opening: the marker appears without a noticeable wait | app F10 | Functional only (S6c). The Mac's disk is too fast to judge the wait | R5: this is the real judgement. After the cable install |
| Open the overview while notes are typesetting: thumbnails update | overview key | Yes: S6d | R6 after the cable install |

Extra checks:
- S3: the Mac is writing (claimed) when the question page is deleted, then Undo or close. Run against the new server
  and against the live code.
- S7: the old helper in the deploy window, already done on Linux; optional here.
- S8: PATCH contents (F9) and race B (`notesUnknown`) through a logging proxy.

## 2. Setup

### 2.1 Checkout and builds

```sh
REPO=~/Documents/ClaudeCode/notizbuch-v3; cd $REPO
export PATH=~/Documents/ClaudeCode/Sascha/.notizbuch-tools/node-v22.23.4-darwin-arm64/bin:$PATH
git fetch origin claude/link-vorschau && git checkout --detach FETCH_HEAD
git rev-list --count HEAD                      # 169, unless the instructions name a later commit
git diff --stat 70bdd64 29dfdae                # exactly 12 files (list below)
git diff --stat 29dfdae HEAD                   # only native/Notizbuch/test/schreiben/mac-test.md
T=$(mktemp -d); export T; mkdir -p $REPO/test-screens/write168
A=91F50B23-AB29-42E8-AB32-9C7ADC4FFF59         # iPad Pro 11-inch (M4), iOS 27.0; always by UDID, never "booted"
B=<UDID of the existing iPhone Air simulator, iOS 27.0>   # xcrun simctl list devices available; create none
xcodebuild -project native/Notizbuch/Notizbuch.xcodeproj -target Notizbuch -configuration Debug \
  -sdk iphonesimulator SYMROOT=$T/build CODE_SIGNING_ALLOWED=NO build
```

The 12 files are:
- Swift: Ask.swift, CanvasController.swift, NoteTypesetter.swift, PDFExport.swift, PageOverview.swift, SyncEngine.swift
- claude-fragen: README.md, helfer.mjs, test/fake-claude, test/helper-test.mjs
- server: src/index.js, test/notizen.mjs

Report every error and every warning in the six Swift files verbatim. A compile error stops part 3: report it with the
smallest fix as a diff.

Build app 162 for B (used in S1b). Use an archive, not a worktree or branch:

```sh
mkdir -p $T/app162 && git archive 0bdd588 native/Notizbuch | tar -x -C $T/app162
(cd $T/app162 && xcodebuild -project native/Notizbuch/Notizbuch.xcodeproj -target Notizbuch -configuration Debug \
  -sdk iphonesimulator SYMROOT=$T/build162 CODE_SIGNING_ALLOWED=NO build)
```

The two apps are `$T/build/Debug-iphonesimulator/Notizbuch.app` (168) and
`$T/build162/Debug-iphonesimulator/Notizbuch.app` (162). Both use bundle id `de.beiglboeck.notizbuch`, so a simulator
holds only one of them at a time.

### 2.2 Suites (optional; for comparing the Mac with Linux)

`ls native/Notizbuch/server/node_modules/.bin/wrangler` must exist; otherwise stop here and install nothing. For each
suite, start a fresh server and stop it afterwards:

```sh
(cd native/Notizbuch/server && npx wrangler dev --ip 127.0.0.1 --port 8791 --var SECRET:testkey --persist-to $T/state-SUITE > $T/wr-SUITE.log 2>&1 &)
BASE=http://127.0.0.1:8791 KEY=testkey node native/Notizbuch/server/test/notizen.mjs      # Linux: 40 passed, 0 failed
```

Run the same for `asks.mjs` (134/0), `mcp.mjs` (59 ok/0), `lernen.mjs` (23 ok/0) and
`native/Notizbuch/claude-fragen/test/helper-test.mjs` (Linux: 305 passed, 0 failed; on the Mac the poppler parts may
be skipped and say so, so the count can be lower). Expected: 0 failed.

### 2.3 Servers and the logging proxy

```sh
(cd native/Notizbuch/server && npx wrangler dev --ip 127.0.0.1 --port 8787 --var SECRET:testkey --persist-to $T/state-new > $T/wrangler-new.log 2>&1 &)
```

A talks to the proxy on 8788, which forwards to 8787. B and the helper talk to 8787 directly. The proxy logs every
request and summarises each `PATCH …/asks`. `curl -s http://127.0.0.1:8788/__hold` holds the asks requests (GET and
PATCH) and `…/__release` lets them through; this is used in S8b only. If something on A looks odd, repeat that step
with A pointed straight at 8787 to rule out the proxy. Save this as `$T/proxy.mjs` and run
`node $T/proxy.mjs 8788 8787 > $T/proxy.log 2>&1 &`:

```js
// node proxy.mjs <listen> <target>: forwards to 127.0.0.1:<target>, pipes WebSocket upgrades, logs every request.
// PATCH …/asks gets a summary. GET /__hold holds every …/asks request (GET and PATCH) until GET /__release
import http from "node:http";
import net from "node:net";
const [listen, target] = process.argv.slice(2).map(Number);
const t = () => new Date().toISOString().slice(11, 23);
const short = (id) => id.slice(0, 8);
let hold = false;
const held = [];
http.createServer(async (req, res) => {
  if (req.url === "/__hold") { hold = true; console.log(t(), "HOLD"); return res.end("hold\n"); }
  if (req.url === "/__release") {
    hold = false;
    console.log(t(), "RELEASE", held.length);
    held.splice(0).forEach((go) => go());
    return res.end("release\n");
  }
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const body = Buffer.concat(chunks);
  const isAsks = /\/asks$/.test(req.url.split("?")[0]);
  let info = "";
  if (req.method === "PATCH" && isAsks) {
    try {
      const j = JSON.parse(body);
      const anchors = Object.entries(j.anchors || {}).map(([id, a]) => `${short(id)}:${a ? a.page : null}`).join(",");
      const notes = Object.fromEntries(Object.entries(j.notes || {}).map(([id, l]) => [short(id), l.map((n) => n.page)]));
      info = ` pv ${j.pv} anchors ${anchors} notes ${JSON.stringify(notes)} notesUnknown ${JSON.stringify((j.notesUnknown || []).map(short))}`;
    } catch {}
  }
  if (hold && isAsks) {
    console.log(t(), "held", req.method, req.url);
    await new Promise((go) => held.push(go));
  }
  console.log(t(), req.method, req.url, `${body.length} B${info}`);
  const skip = new Set(["host", "connection", "content-length", "transfer-encoding"]);
  try {
    const up = await fetch(`http://127.0.0.1:${target}${req.url}`, {
      method: req.method,
      headers: Object.fromEntries(Object.entries(req.headers).filter(([k]) => !skip.has(k))),
      body: body.length ? body : undefined,
    });
    res.writeHead(up.status, Object.fromEntries([...up.headers].filter(([k]) => !skip.has(k) && k !== "content-encoding")));
    res.end(Buffer.from(await up.arrayBuffer()));
  } catch (e) {
    res.writeHead(502).end(String(e));
  }
}).on("upgrade", (req, socket, head) => {
  const up = net.connect(target, "127.0.0.1", () => {
    up.write(`${req.method} ${req.url} HTTP/1.1\r\n${Object.entries(req.headers).map(([k, v]) => `${k}: ${v}`).join("\r\n")}\r\n\r\n`);
    if (head.length) up.write(head);
    socket.pipe(up).pipe(socket);
  });
  up.on("error", () => socket.destroy());
  socket.on("error", () => up.destroy());
}).listen(listen, "127.0.0.1", () => console.log(t(), `proxy ${listen} -> ${target}`));
```

The live code (0bdd588) is used for S3a only. Start it then:

```sh
mkdir -p $T/live && git archive 0bdd588 native/Notizbuch/server | tar -x -C $T/live
ln -s $REPO/native/Notizbuch/server/node_modules $T/live/native/Notizbuch/server/node_modules
(cd $T/live/native/Notizbuch/server && npx wrangler dev --ip 127.0.0.1 --port 8789 --var SECRET:testkey --persist-to $T/state-live > $T/wrangler-live.log 2>&1 &)
```

### 2.4 Helper with the fake Claude

```sh
export FAKE_STATE=$T/fake; mkdir -p $FAKE_STATE $T/helfer
echo '{"mode":"ok"}' > $FAKE_STATE/mode.json
printf '{"url":"http://127.0.0.1:8787","key":"testkey","claude":"%s/native/Notizbuch/claude-fragen/test/fake-claude"}' "$REPO" > $T/helfer/config.json
chmod 600 $T/helfer/config.json
BETTERNOTES_HELFER_HOME=$T/helfer BETTERNOTES_HELFER_ECHO=1 FAKE_STATE=$FAKE_STATE \
  node native/Notizbuch/claude-fragen/helfer.mjs > $T/helfer.out 2>&1 & echo $! > $T/helfer.pid
```

- The fake Claude reads `mode.json` when it starts, so write the mode BEFORE the ask is claimed. `delayMs` is how long
  „Claude works“.
- Write modes:
  - `writePage`: one note „Lösung unter dem Auftrag“ (x 10 %, y 60 %, width 80 %) on the page that the prompt names in
    „die ganze Seite N“ (N counts from 1; page 1 without a number), plus one note „Fortsetzung“ (x 10 %, y 10 %) on the
    next page.
  - `writeLong`: one 8000-character note on page 1 (index 0).
  - `writeMany`: 150 notes on page 1; the server keeps 100.
  - `write`: formulas, one note with a red box.
- Helper log: `$T/helfer/helfer.log`. The real osascript stays in use, because the PDF page window needs PDFKit.

### 2.5 Server address and key of the app (simulator)

Use way 1. Set the values after installing and before the first launch, while the app is not running:

```sh
xcrun simctl boot $A; xcrun simctl bootstatus $A -b
xcrun simctl terminate $A de.beiglboeck.notizbuch; xcrun simctl uninstall $A de.beiglboeck.notizbuch
xcrun simctl spawn $A defaults delete de.beiglboeck.notizbuch          # ignore "not found"
xcrun simctl install $A $T/build/Debug-iphonesimulator/Notizbuch.app
xcrun simctl spawn $A defaults write de.beiglboeck.notizbuch syncURL http://127.0.0.1:8788   # A through the proxy
xcrun simctl spawn $A defaults write de.beiglboeck.notizbuch syncKey testkey
xcrun simctl launch $A de.beiglboeck.notizbuch
```

Do the same for B with `syncURL http://127.0.0.1:8787`.

Other ways, for reference:
- Way 2: from the library, open the setup link `xcrun simctl openurl $A "notizbuch://setup?url=http://127.0.0.1:8787&key=testkey"`.
  An alert „Mit diesem Server synchronisieren?“ appears; confirm it.
- Way 3: the gear in the library, then server address and key.

Plain http to 127.0.0.1 worked in earlier rounds, without an ATS exception. Never enter the real server or key.

### 2.6 Logs, commands and scripts

Logs:

```sh
xcrun simctl spawn $A log stream --style compact --predicate 'eventMessage CONTAINS "Asks-Debug" OR (subsystem == "de.beiglboeck.notizbuch" AND category == "sync")' > $T/app-A.log &
xcrun simctl spawn $B log stream --style compact --predicate 'eventMessage CONTAINS "Asks-Debug" OR (subsystem == "de.beiglboeck.notizbuch" AND category == "sync")' > $T/app-B.log &
```

Debug commands (Debug build only) are sent as `xcrun simctl openurl $A "notizbuch://debug/<command>"`. Wait about
1.5 s after each unless the step says otherwise. If „Open in BetterNotes?“ appears, confirm it; if it hangs, reboot
that simulator by UDID.

- Library only:
  - `debug/new`: creates a notebook and opens it. Never send it while the editor is open.
  - `debug/import?file=<name in Documents>`
- Editor:
  - `debug/ask?page=N[&effort=thorough][&mode=write]`: page index from 0; draws three squiggles at the top left if the page is empty.
  - `debug/card?ask=first|last|<id>`
  - `debug/delete?ask=…`
  - `debug/pages?delete=N`
  - `debug/pages?insert=N`: a blank page becomes page N.
  - `debug/pages?undo`
  - `debug/pages?done`: drops the undo window.
  - `debug/tool?overview=1|0`: opens or closes the page overview. Closing it drops the undo window, but only if it was open.
  - `debug/state`

Each command logs `Asks-Debug: …`. Half a second later it logs
`Asks-Debug: Stand: pv P, N Seiten, M Markierungen: <id8> <status> Seite <page> pv <pv> [versteckt] [löscht] [verschoben]`.
The Stand line shows no notes; use the scripts below for those. No command opens an existing document: tap its tile in
the library. After every launch the editor is closed.

Reading anchors:
- A notebook page is 768 × 1086 page points.
- The squiggles of `debug/ask` give a question anchor of about x 78, y 108, width 265.
- A marker that moved to a writePage note has the note's width, about 614.
- The bubble sits at the anchor's top right: about x 340 next to the squiggles, about x 690 at the end of a note.

Save these in `$T` (node, no packages):

```sh
cat > $T/lib.mjs <<'EOF'
// node lib.mjs <port>: documents on the server, newest first
const [port] = process.argv.slice(2);
const { docs = [] } = await (await fetch(`http://127.0.0.1:${port}/api/library`, { headers: { Authorization: "Bearer testkey" } })).json();
for (const d of docs.sort((a, b) => (b.created || 0) - (a.created || 0))) console.log(d.id, d.kind, `„${d.title}“`, `Seiten ${d.pageCount}`, `pv ${d.pagesVersion ?? 0}`);
EOF
cat > $T/asks.mjs <<'EOF'
// node asks.mjs <port> <doc>: the server's asks of a document
const [port, doc] = process.argv.slice(2);
const { asks = [] } = await (await fetch(`http://127.0.0.1:${port}/api/doc/${doc}/asks`, { headers: { Authorization: "Bearer testkey" } })).json();
const n = (x) => Math.round(Number(x) || 0);
for (const a of asks) {
  const an = a.anchor || {};
  const hint = (a.answer || "").match(/\*\((Eine Notiz fehlt|\d+ Notizen fehlen)/);
  console.log(a.id.slice(0, 8), a.mode || "frage", a.status, `pv ${a.pv}`, `Seite ${an.page} (x ${n(an.x)} y ${n(an.y)} w ${n(an.w)})`,
    `Notizen ${JSON.stringify((a.notes || []).map((x) => x.page))}`, `Zeichen ${(a.notes || []).map((x) => x.text.length).join("+")}`,
    a.note ? `note „${a.note}“` : "", hint ? `Hinweis „${hint[1]}“` : "");
}
EOF
cat > $T/local.mjs <<'EOF'
// node local.mjs <udid> <doc>: asks.json of a document in the app on that simulator
import { execFileSync } from "node:child_process";
import fs from "node:fs";
const [udid, doc] = process.argv.slice(2);
const data = execFileSync("xcrun", ["simctl", "get_app_container", udid, "de.beiglboeck.notizbuch", "data"]).toString().trim();
const f = JSON.parse(fs.readFileSync(`${data}/Documents/Notizbuch/${doc}/asks.json`, "utf8"));
const n = (x) => Math.round(Number(x) || 0);
console.log(`format ${f.format} v ${f.v}`);
for (const a of f.asks) {
  const an = a.anchor || {}, pa = a.parkedAnchor;
  console.log(a.id.slice(0, 8), a.mode || "frage", a.status, `pv ${a.pv}`, `Seite ${an.page} (y ${n(an.y)} w ${n(an.w)})`,
    ["hidden", "deleting", "moved", "notesMoved", "claimedAtHide"].filter((k) => a[k]).join(" "),
    pa ? `parkedAnchor Seite ${pa.page} (y ${n(pa.y)} w ${n(pa.w)})` : "",
    `Notizen ${JSON.stringify((a.notes || []).map((x) => (x.parked != null ? `${x.page}/geparkt ${x.parked}` : x.page)))}`);
}
EOF
cat > $T/calls.mjs <<'EOF'
// node calls.mjs [n]: the last n calls of the fake Claude: chat, ask id, question page named in the prompt
import fs from "node:fs";
const n = Number(process.argv[2]) || 4;
const calls = fs.readFileSync(`${process.env.FAKE_STATE}/calls.jsonl`, "utf8").trim().split("\n").map((l) => JSON.parse(l)).filter((c) => c.args);
for (const c of calls.slice(-n)) {
  const a = c.args, i = a.indexOf("-p"), p = i >= 0 ? String(a[i + 1]) : "";
  const chat = a.includes("--resume") ? `--resume ${String(a[a.indexOf("--resume") + 1]).slice(0, 8)}` : `--session-id ${String(a[a.indexOf("--session-id") + 1]).slice(0, 8)}`;
  console.log(chat, (p.match(/fragen\/([0-9A-Fa-f-]{36})\//) || [])[1]?.slice(0, 8) || "-", (p.match(/die ganze Seite( \d+)?/) || [""])[0],
    /ist noch der Stand vor der letzten Seitenänderung/.test(p) ? "ALTES-PDF" : "");
}
EOF
cat > $T/outbox.mjs <<'EOF'
// node outbox.mjs <port>: Claude's outbox, newest first; saves the newest PNG to $T
import fs from "node:fs";
const [port] = process.argv.slice(2);
const base = `http://127.0.0.1:${port}/api/outbox/claude`, h = { Authorization: "Bearer testkey" };
const { files = [] } = await (await fetch(base, { headers: h })).json();
for (const f of files.slice(0, 6)) console.log(f.created, f.size, f.name);
const png = files.find((f) => f.name.endsWith(".png"));
if (png) {
  const out = `${process.env.T}/outbox-${Date.now()}.png`;
  fs.writeFileSync(out, Buffer.from(await (await fetch(`${base}/${encodeURIComponent(png.name)}`, { headers: h })).arrayBuffer()));
  console.log("gespeichert:", out);
}
EOF
```

Take screenshots with `xcrun simctl io $A screenshot $REPO/test-screens/write168/<step>.png`. Find the document id with
`node $T/lib.mjs 8787`; the same uppercase UUID names the app folder.

Notebook preparation, used by most steps:
1. In the library, send `debug/new`. Tap the toolbar to edit if needed.
2. Send `debug/pages?insert=1` until `debug/state` reports at least 6 pages (`Seiten`).
3. Open the same notebook on B by tapping it in the library.

## 3. Simulator checks

At the start, A and B both run 168. In each step, „server“ means `node $T/asks.mjs 8787 $DOC`, „A local“ means
`node $T/local.mjs $A $DOC`, and „proxy“ means `$T/proxy.log`.

### S1: delete the question page, Undo, delete again and close (F2), with second device B

1. Set up notebook S1. Then `echo '{"mode":"writePage","delayMs":3000}' > $FAKE_STATE/mode.json` and send
   `debug/ask?page=1&mode=write` to A.
   - Server: answered, page 1 (w ≈ 265), notes [1,2].
   - A and B show the bubble next to the squiggles, „Lösung unter dem Auftrag“ low on page index 1 and „Fortsetzung“
     at the top of index 2. Take screenshots s1-1-A and s1-1-B.
2. On A: `debug/tool?overview=1`, then `debug/pages?delete=1`.
   - A local: anchor page 1, w ≈ 614 (the „Fortsetzung“ note, now index 1); parkedAnchor page 1, w ≈ 265; notes
     [`-1/geparkt 1`, 1].
   - Proxy: one PATCH with the new anchor and notes [-1,1] for this ask.
   - Server: answered, page 1, w ≈ 614, notes [-1,1].
   - B: the bubble at the right end of „Fortsetzung“ (x ≈ 690) and one note. The ask must not disappear anywhere.
3. On A: `debug/pages?undo`.
   - A local: anchor back to w ≈ 265 (the squiggles are back), notes [1,2], no parkedAnchor.
   - Server: page 1, w ≈ 265, notes [1,2].
   - B: as in step 1.
4. On A: `debug/pages?delete=1` again, then `debug/tool?overview=0`.
   - A local, server and B: anchor page 1, w ≈ 614, notes [1], no parkedAnchor.
   - The ask stays answered on all three. Before the fix, closing the overview deleted it and all its notes everywhere.
5. Restart A (`xcrun simctl terminate`/`launch`) and open S1: still the same, no parkedAnchor, notes [1].
6. S1b, with B on 162:
   - On B: terminate, uninstall, `defaults delete`, install the 162 app, `defaults write` syncURL 8787 and syncKey,
     launch. Open S1 on B.
   - Repeat steps 1–4 with a new write ask on A on page 2 (`debug/ask?page=2&mode=write`; notes [2,3]; after the
     delete the bubble is at „Fortsetzung“, now index 2).
   - Expect the same on A and on the server. B (162) follows the anchor and the notes: at the note after the delete,
     back after Undo, at the note after delete and close.
7. S1c, with 162 as the device that changes pages. This documents residual 1 and is not a failure.
   - On B (162): open the overview, delete the question page of the ask from step 6, close the overview.
   - Expected old behaviour: the ask and all its notes vanish on B, A and the server.

### S2: the answer arrives while the question page is deleted (F1), then Undo or close

1. Set up notebook S2 on A. Stop the helper with `kill $(cat $T/helfer.pid)`. Then
   `echo '{"mode":"writePage"}' > $FAKE_STATE/mode.json`.
2. On A: `debug/tool?overview=1`, then `debug/ask?page=1&mode=write`. The server shows it open, page 1.
3. On A: `debug/pages?delete=1`. The Stand line shows `open … versteckt`; the server shows page -1.
4. Start the helper again (2.4).
   - Helper log: the claim, and `Unterlagen: ohne Nachbarseiten (Seite gelöscht), …`.
   - `node $T/calls.mjs 1`: the prompt says „die ganze Seite“ without a number.
   - Server: answered, page -1, notes [0,1].
5. Wait until A local shows the hidden ask with notes [0,1] (no claimedAtHide). Then send `debug/pages?undo`.
   - A local and server: answered, page 1 (w ≈ 265), notes [0,2]. The note from page index 1 moved with the restored
     page to index 2. Before the fix (F1), the notes stayed [0,1].
6. S2b: repeat steps 1–4 with a new ask. Instead of Undo, send `debug/tool?overview=0`.
   - The ask stays and moves to its first note: page 0, y ≈ 652, w ≈ 614 („Lösung unter dem Auftrag“). Notes [0,1].
     Server the same.
   - Before the fix, the ask was deleted.

### S3: the Mac is already writing when the question page is deleted (claimedAtHide)

S3b runs on the new server (8787):
1. Set up notebook S3.
2. `echo '{"mode":"writePage","delayMs":20000}' > $FAKE_STATE/mode.json`. On A: `debug/tool?overview=1`, then
   `debug/ask?page=1&mode=write`.
3. Once the server shows it claimed, send `debug/pages?delete=1`. A local shows hidden and claimedAtHide.
4. About 20 s later, the server shows: answered, page -1, notes [], hint „2 Notizen fehlen“.
5. `debug/pages?undo`: the ask is back on page 1 with the answer and the hint, but no notes. This is residual 4 and is
   expected.
6. Repeat with `debug/tool?overview=0` instead of Undo: the ask is deleted on A and on the server, because the Mac was
   already writing.

S3a runs on the live code (8789), the state between the app install and the server deploy (optional when the server
is deployed first). Do it last, after S8, because A has to be reinstalled for it:
1. Stop the 8787 helper.
2. Start a second test helper with `$T/helfer-live/config.json` (url 8789) and `FAKE_STATE=$T/fake-live`.
3. Reinstall A with `syncURL http://127.0.0.1:8789`.
4. Repeat S3b steps 1–5.
   - After the answer, the server shows answered, page -1, notes [1,2]: the old server stores the claim-time numbering.
   - A local: hidden, claimedAtHide, notes [1,2], not renumbered.
   - After Undo: page 1, notes [1,2], which is correct.
   - With close instead of Undo: deleted.
5. Then go on with the cleanup (part 5).

### S4: a page inserted while Claude works (case A, SH-F1)

S4a, notebook:
1. Set up notebook S4. With mode `{"mode":"ok"}`, send `debug/ask?page=0` (a normal question that opens the
   document's chat) and wait until it is answered.
2. `echo '{"mode":"writePage","delayMs":20000}' > $FAKE_STATE/mode.json`, then
   `debug/ask?page=1&effort=thorough&mode=write`.
3. Once the server shows claimed, send `debug/pages?insert=0`.
4. During the next ~20 s, `debug/card?ask=last` shows the waiting card (screenshot s4a-card). After the refusal the
   server reopens the ask with the note „Die Seiten haben sich geändert: Claude schreibt noch einmal“. The helper takes
   it again within milliseconds, and taking it clears the note. So the card will most likely never show that text;
   do not count it as a failure. The helper log is the reliable sign.

Expected within about 45 s:
- Helper log for this ask, in this order:
  - `übernommen: „…“, Seite 2, gründlich, schreibt ins Dokument`
  - `Seiten haben sich geändert, während Claude schrieb: noch einmal, in einem neuen Chat`
  - `übernommen: …, Seite 3, …`
  - exactly one `beantwortet nach … s (… Zeichen), 2 Notizen ins Dokument`
- `node $T/calls.mjs 2`: the first run has `--resume <the chat of step 1>` and „die ganze Seite 2“. The second run has
  `--session-id <new>` and „die ganze Seite 3“.
- Server: answered, page 2, notes [2,3], pv = A's current pv.
- A shows „Claude hat geantwortet“ once. The notes sit under the squiggles on index 2 and at the top of index 3. B
  shows the same.

S4b, all notes under the question:
1. `echo '{"mode":"writeLong","delayMs":20000}' > $FAKE_STATE/mode.json`.
2. In a new notebook S4b, send `debug/ask?page=0&effort=thorough&mode=write`. Once it is claimed, send
   `debug/pages?insert=0`.
3. Expected:
   - One Claude call and no „Seiten haben sich geändert“ line.
   - About 20 s after the claim: `beantwortet nach 2x s (…), 1 Notizen ins Dokument (1 gekürzt)`. The bubble ends
     with „Eine Notiz war zu lang und ist gekürzt.“ (the helper cuts it now, without a half character pair).
   - Server: page 1, notes [1], text length 7999 (`Zeichen 7999`). The note moved with its page.

S4c, PDF:
1. Save this 12-page PDF generator as `$T/zwoelf.py` (python3 from the Xcode tools):

```python
import sys
objs = []
def add(s):
    objs.append(s)
    return len(objs)
font = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
contents = []
for n in range(1, 13):
    s = (f"BT /F1 48 Tf 72 720 Td (Seite {n}) Tj ET "
         f"BT /F1 14 Tf 72 680 Td (Gedruckter Text auf Seite {n} des Test-PDFs.) Tj ET")
    contents.append(add(f"<< /Length {len(s)} >>\nstream\n{s}\nendstream"))
parent = len(objs) + 13
kids = [add(f"<< /Type /Page /Parent {parent} 0 R /MediaBox [0 0 595 842] "
            f"/Resources << /Font << /F1 {font} 0 R >> >> /Contents {c} 0 R >>") for c in contents]
assert add(f"<< /Type /Pages /Kids [{' '.join(f'{k} 0 R' for k in kids)}] /Count {len(kids)} >>") == parent
root = add(f"<< /Type /Catalog /Pages {parent} 0 R >>")
out, offsets = bytearray(b"%PDF-1.4\n"), []
for i, o in enumerate(objs, 1):
    offsets.append(len(out))
    out += f"{i} 0 obj\n{o}\nendobj\n".encode("latin-1")
xref = len(out)
out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode()
for off in offsets:
    out += f"{off:010d} 00000 n \n".encode()
out += f"trailer\n<< /Size {len(objs) + 1} /Root {root} 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
open(sys.argv[1], "wb").write(out)
```

2. Run `python3 $T/zwoelf.py "$(xcrun simctl get_app_container $A de.beiglboeck.notizbuch data)/Documents/zwoelf.pdf"`.
3. From the library, send `debug/import?file=zwoelf.pdf`. Wait for `PUT /api/pdf/…` in the proxy log.
4. Mode `{"mode":"writePage","delayMs":20000}`. Send `debug/ask?page=2&effort=thorough&mode=write`. Once it is claimed,
   send `debug/pages?insert=0`.
5. Expected:
   - Helper log: `Seiten haben sich geändert …`.
   - Maybe `PDF am Server noch vor der letzten Seitenänderung, neuer Versuch in … s`, while A still uploads the new
     PDF.
   - The second run's `Unterlagen: …` line has `PDF-Fenster … von 13` and not „noch vom Stand vor der letzten
     Seitenänderung“.
   - `node $T/calls.mjs 1`: `--session-id`, „die ganze Seite 4“, no ALTES-PDF.
   - Server: page 3, notes [3,4].

### S5: restart while the undo window is open (F6)

1. Notebook S5: an answered writePage ask on page 1 (notes [1,2]).
2. On A: `debug/tool?overview=1`, then `debug/pages?delete=2`. A local: notes [1, `-1/geparkt 2`]. Server: [1,-1].
3. `xcrun simctl terminate $A de.beiglboeck.notizbuch`, then launch it and stay in the library for 30 s.
   - Proxy: a PATCH for S5 with notes [1], sent without opening the document, because it counted as pending.
   - Server: notes [1].
4. Open S5. A local: notes [1], no „geparkt“, no parkedAnchor, format 2. Undo is gone.
5. S5b, the question page:
   - In a new notebook, create an answered writePage ask on page 1. Open the overview and send `debug/pages?delete=1`.
     The bubble moves to „Fortsetzung“ and parkedAnchor is set.
   - Terminate and launch again.
   - Expected: no parkedAnchor, the anchor stays at the note (page 1, w ≈ 614), notes [1]. Server the same.

### S6: typesetting (F8, F10). Shut B down first: `xcrun simctl shutdown $B`

Preparation, on A:
- Notebook „Viele“: mode `{"mode":"writeMany"}`, then `debug/ask?page=0&mode=write`. The result is 100 notes on page
  0, and the bubble text ends with „50 Notizen passten nicht mehr ins Dokument und fehlen“.
- Notebook „Formeln“: mode `{"mode":"write"}`, then `debug/ask?page=1&mode=write`. The result is the integral note on
  index 0 and the red-boxed „Vorzeichen: −2“ on index 1. The notes on pages 12 and 40 are dropped. The bubble says
  „2 Notizen standen auf Seiten, die es nicht gibt, und fehlen.“

Wait until all the text is visible. Set `DATA=$(xcrun simctl get_app_container $A de.beiglboeck.notizbuch data)`.

- S6a, sharing right after opening, with the typeset files on disk but none in memory:
  1. Terminate and launch A, then tap „Formeln“.
  2. Within 2 s: share button, „An Claude senden“, „Diese Seite“, with page 1 in view.
  3. Expect „Wird gesendet …“ and then success.
  4. `node $T/outbox.mjs 8788`: the saved PNG shows the typeset integral (not empty, not raw `$$`).
- S6b, the same without the files:
  1. Terminate A, then `rm -rf "$DATA/Library/Caches/notizen"`.
  2. Launch, open „Formeln“, share page 1 at once.
  3. The PNG shows the integral: the export waited for typesetting, at most 5 s. Before the fix, it came out without
     the text.
- S6c, asking right after opening:
  1. Terminate and launch A, then tap „Viele“.
  2. As soon as the page shows, send `debug/ask?page=0`, then `debug/state` after 1 s and after 3 s.
  3. Expected: the new ask, and one more Markierung, already appear in the Stand line at 1 s. The bubble and the flash
     „Frage an Claude geschickt“ appear in a screenshot taken right away.
  4. Report the times. The simulator cannot show the device's wait; that is R5.
  5. Optionally, repeat after deleting the notizen folder. The marker then may wait for typesetting of the question's
     page (at most 5 s). Report the time.
- S6d, the overview while typesetting:
  1. Terminate A, then delete the notizen folder. Launch, tap „Viele“, and at once send `debug/tool?overview=1`.
  2. Take screenshots at 1, 3, 6 and 12 s.
  3. Expected: the thumbnail of page 1 fills in the „Fehler …“ texts while the overview stays open, without closing
     and reopening it.
- S6e, background while typesetting:
  1. Terminate A, then delete the notizen folder. Launch and tap „Viele“.
  2. About 1 s later, send `xcrun simctl launch $A com.apple.Preferences`; the app goes to the background.
  3. Then run `pkill -f 'RuntimeRoot.*com.apple.WebKit.WebContent'`. This kills only simulator processes, and B is shut
     down. Before running it, check with `pgrep -fl 'RuntimeRoot.*com.apple.WebKit.WebContent'` that nothing outside
     the simulator matches.
  4. Wait 60 s, then send `xcrun simctl launch $A de.beiglboeck.notizbuch`. Take screenshots at 2, 10 and 20 s.
  5. Expected:
     - All texts are visible by about 20 s.
     - `app-A.log` has `Notiz nicht gesetzt (noch einmal): …` (one or more), and no `Notiz nicht gesetzt:` line without
       „(noch einmal)“.
  6. If the screenshot before backgrounding already showed every text, repeat with the background command sent
     immediately after the tap.

### S7: the old helper in the deploy window (optional; done on Linux, 12/12)

1. `mkdir -p $T/old && git show 0bdd588:native/Notizbuch/claude-fragen/helfer.mjs > $T/old/helfer.mjs`, and the same
   for `weitere-seiten.mjs`.
2. Stop the test helper. Start `$T/old/helfer.mjs` with the same environment and config.
3. Repeat S4a.
4. Expected:
   - `inzwischen neu vergeben`, then two `beantwortet nach …` lines. The first one is misleading: it belongs to the
     refused run.
   - The second run has `--resume` with the same chat, and „die ganze Seite 3“.
   - Notes [2,3]. That is still correct; only the chat is reused (residual 9).
5. Restart the new helper afterwards.

### S8: PATCH contents (F9) and race B through the proxy

S8a, which notes go up with a page change:
1. Notebook S8 with at least 8 pages:
   - X: mode `writeLong`, then `debug/ask?page=0&mode=write`; notes [0].
   - Y: mode `writePage`, then `debug/ask?page=2&mode=write`; notes [2,3].
   - Z: `debug/ask?page=4&mode=write`; notes [4,5].
2. Send `debug/pages?insert=3`.
3. Expected:
   - The proxy shows one PATCH with anchors for X, Y and Z (`X:0, Y:2, Z:5`), notes for Y ([2,4]) and Z ([5,6]) only,
     and `notesUnknown []`. X's notes are not sent. Report the body size.
   - `pages: ok` follows within about 1–2 s of the command.
   - Before the fix, every page-change PATCH carried the full notes of X, Y and Z.

S8b, race B (`notesUnknown`):
1. Mode `{"mode":"writePage","delayMs":15000}`, then send `debug/ask?page=6&mode=write` (W).
2. Once W is claimed, run `curl -s http://127.0.0.1:8788/__hold`.
3. Wait until `node $T/asks.mjs 8787 $DOC` shows W answered with notes [6,7]. A does not know this yet.
4. Send `debug/pages?insert=0`. `pages: ok` comes after about 4 s; the page change waits that long for the held list.
5. Run `curl -s http://127.0.0.1:8788/__release`.
6. Expected:
   - Proxy: the held GET goes through, then a PATCH with `W:7` in anchors, `notesUnknown ["W…"]`, and no notes for W.
   - Server: W answered, page 7, notes [7], hint „Eine Notiz fehlt“. This is residual 3: the off-page note is
     dropped, with a hint.
   - A: W on page 7 with one note.
   - Before the fix, the notes stayed [6,7] at the new pv, so the first note sat one page above the question.

## 4. Real devices (Mathias), after the cable install and the deploy

R0. Deploy, then install (residual 9, APP-LOGIC-1):
1. Server and helper first (Mathias): the server script with `claude/link-vorschau` and, right after it,
   `zsh native/Notizbuch/claude-fragen/einrichten.sh` from the updated checkout, in the same minute. Do not use
   „Claude schreiben lassen“ with page changes between the two (an old helper would re-run in the same chat).
2. Then the app by cable: the Release build of 169, installed with devicectl over the installed app (bundle id
   `de.beiglboeck.notizbuch.R5W5PMUZKF`), after a backup of its data container; never uninstall. Deploying first
   avoids a rare race of the new app with the old server (S3a shows that window). If the app has to go on first,
   avoid deleting the question page of a write ask while Claude writes until the deploy.
3. Checks:
   - The wrangler output says the worker was deployed.
   - `shasum -a 256 ~/Library/Application\ Support/BetterNotes-Helfer/helfer.mjs` equals
     `git show 29dfdae:native/Notizbuch/claude-fragen/helfer.mjs | shasum -a 256`. Do the same for weitere-seiten.mjs.
   - helfer.log shows the helper starting after the update.
   - The gear window of the app shows version 169.

R2, R3, R4, R5 and R6 need only the cable install. R1 and R7 need the deploy.

R1, case A with real Claude (after the deploy):
- R1a:
  1. On the iPad (169), in a throwaway notebook, write a task near the bottom of page 2 whose solution needs more
     room, for example a calculation with several steps.
  2. Lasso it and choose „Claude gründlich schreiben lassen“.
  3. While the bubble shows dots, open the overview, insert a page above page 2 and close the overview.
  4. Expected:
     - The bubble keeps waiting, with no error.
     - The card may show „Die Seiten haben sich geändert: Claude schreibt noch einmal“ only for a moment, if at all:
       the helper takes the ask again at once, which clears the note.
     - The answer arrives once („Claude hat geantwortet“ once). The notes sit under the task and continue on the
       following page, in the new numbering. The iPhone shows the same.
     - helfer.log (read only), one of two patterns: `Seiten haben sich geändert, während Claude schrieb: noch einmal,
       in einem neuen Chat` and then one `beantwortet nach …`; or a single `beantwortet nach …` if all notes were
       under the task.
- R1b: a short task that fits under itself, with a page inserted while Claude works. One answer, about as fast as
  without the insert, and the notes moved with the page.

R2, F2 on devices:
1. Use an answered write ask whose notes are partly on another page.
2. On the iPad (169): delete the question's page in the overview. The bubble moves to the first remaining note.
3. Rückgängig: everything is back.
4. Delete the page again and close the overview: the bubble stays at the note, and the other notes stay.
5. The iPhone (162 or 169) shows the same at each step, and so does the 154 app on the iPad Pro (it behaves like 162).
6. Do not delete the question page on a 162 or 154 device: it still deletes the whole ask (residual 1).

R3, background:
1. Open a document with many and long notes right after a long answer arrived, or right after a fresh start.
2. Press Home, use other apps for a minute, then come back.
3. Expected: within a few seconds all notes show text, not just their boxes.

R4, sharing right after opening:
1. Force-quit the app, reopen it and open a document with notes.
2. Immediately use „Teilen“, „Diese Seite als Bild“ (or „An Claude senden“, „Diese Seite“).
3. Expected: the image or PDF contains the note text.

R5, asking right after opening:
1. Force-quit the app, reopen it and open a document with many notes (for example the writeMany kind, or a long
   answer).
2. Immediately lasso a question on a page with notes and choose „Claude fragen“.
3. Expected: the bubble appears within about a second, with no noticeable stall when opening or scrolling.

R6, overview: right after opening that document after a fresh start, open the page overview. The thumbnails fill in
the note text within seconds, without reopening the overview.

R7, sanity after the deploy:
- „Claude fragen“ and „Claude schreiben lassen“ without page changes on 169 and on 162: answered as before.
- „Claude fragen“ on 154.

## 5. Cleanup

1. Stop the log streams, the test helpers (`kill $(cat $T/helfer.pid)` and the live/old ones), the proxy and every
   wrangler you started: `pkill -f "wrangler dev --ip 127.0.0.1 --port 87"` and check `pgrep -fl workerd`.
2. On A and B: `defaults delete de.beiglboeck.notizbuch`, uninstall the app, shut the simulators down.
3. `rm -rf $T`. Keep `test-screens/write168/`.
4. Check that nothing is left listening: `lsof -nP -iTCP -sTCP:LISTEN | grep -E '87(87|88|89|91)'` is empty.

## 6. Report

For each S and R step:
- The commands' Stand lines with timestamps.
- `asks.mjs` and `local.mjs` output at each checkpoint.
- The proxy lines for PATCHes, the helper log lines of the ask, and `calls.mjs` output.
- Screenshots.

Mark every deviation from „Expected“ with the exact text you saw. Include the build warnings and errors of 2.1 in
full, and the suite counts if 2.2 was run.
