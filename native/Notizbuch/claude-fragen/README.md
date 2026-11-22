# „Claude fragen“: der Helfer am Mac

In der Notizbuch-App eine handgeschriebene Frage mit dem Lasso markieren und im Menü **Claude fragen** (knapp) oder **Claude gründlich fragen** wählen. Neben der Frage erscheint eine Sprechblase. Ist die Antwort da, wird sie blau; antippen zeigt die Antwort mit Formeln. Dort lässt sich die Markierung auch wieder löschen, auf allen Geräten. Die Markierungen gibt es nur in der App, nicht im PDF, nicht im Export und nicht im geteilten Link.

Beantwortet wird am Mac: Dieser Helfer läuft dort im Hintergrund und bekommt jede neue Frage sofort vom Notizbuch-Server gemeldet. Er fragt Claude Code (`claude -p`) mit dem Bild der Frage, der ganzen Seite, den beschriebenen Seiten davor und danach, wie sie in der App aussehen (bei „Claude fragen“ aus drei davor und einer danach, gründlich aus sieben davor und zwei danach; die App schickt sie als ein PDF mit, ohne die leeren), und, bei PDFs, dem Dokument. Claude darf dabei im Internet nachschlagen; die Quellen stehen dann als Links unter der Antwort (antippen öffnet sie im Browser). Bei einem PDF mit mehr als 10 Seiten bekommt Claude zuerst die Seiten um die Frage als eigenes kleines PDF (bei „Claude fragen“ drei davor und eine danach, gründlich sieben davor und zwei danach); das ganze PDF liegt daneben. Je Dokument gibt es einen eigenen Chat, der mit jeder Frage weitergeht: Claude kennt die früheren Fragen zum selben Dokument. Wird ein Chat zu groß für Claude (jede Frage bringt Bilder und Seiten mit), fängt der Helfer für die nächste Frage einen neuen an.

Ist der Mac aus oder im Ruhezustand, warten die Fragen am Server und werden beantwortet, sobald er wieder läuft. Ist das Nutzungslimit von Claude erreicht, zeigt die App das an, und der Helfer macht weiter, sobald das Limit vorbei ist (im Zweifel nach 30 Minuten).

## Einrichten

Einmal im Terminal, im Ordner des Repos:

```sh
zsh native/Notizbuch/claude-fragen/einrichten.sh
```

Das Skript braucht `node` (am besten 22 oder neuer; es findet auch die Kopie in `Sascha/.notizbuch-tools`). Liegt node in Dokumente, Schreibtisch oder Downloads (wie diese Kopie), legt es eine Kopie neben den Helfer: macOS lässt einen Dienst im Hintergrund dort ohne eigene Freigabe nichts starten. Am Ende wartet es, bis der Helfer läuft, und zeigt sonst, was macOS dazu meldet. URL und Schlüssel des Servers liest es aus `~/Documents/ClaudeCode/Sascha/notizbuch-zugang.txt` und legt sie nur in der Einstellungsdatei des Helfers ab. Nach einem Update des Repos dasselbe Skript noch einmal ausführen.

Claude Code muss am Mac angemeldet sein, und zwar für den Helfer selbst: Die Claude-App gibt ihre Anmeldung nur an ihre eigenen Sitzungen weiter. Am einfachsten ist Claude Code fürs Terminal (`~/.local/bin/claude`): einmal `claude` starten und anmelden. Ohne diese Installation nimmt der Helfer die Kopie aus der Claude-App (die neueste Version; er sucht sie vor jeder Frage selbst, weil sich ihr Pfad mit jedem Update der App ändert), die dann ebenso einmal selbst angemeldet sein muss. Ist Claude Code nicht da oder abgemeldet, zeigt die App das bei der Frage an, am Mac erscheint ein Hinweis, und der Helfer schaut alle zwei Minuten nach (`claude auth status`, kostet keine Nutzung): Kurz nach dem Anmelden geht es weiter. Erscheint am Mac kein Hinweis, die Mitteilungen einmal erlauben: im Skript-Editor `display notification "Test"` ausführen und zulassen.

Der Server muss die Fragen schon kennen (Server-Update). Sonst steht im Protokoll „Server-Update nötig“, und der Helfer wartet.

## Was Claude dabei darf

Lesen, und zwar nur im Ordner des Dokuments (`chats/<Dokument>` im Ordner des Helfers, mit den Bildern der Fragen und dem PDF), und im Internet suchen, etwa nach Definitionen, Sätzen oder Literatur. Ganze Seiten liest Claude nur von ausgewählten Fachseiten (Wikipedia, arXiv, MathOverflow, nLab, zbMATH und einige mehr, siehe `webSites` unten); andere Seiten kennt es nur aus den Suchergebnissen. Claude Code läuft dafür nur mit den Werkzeugen Read, WebSearch und WebFetch, ohne MCP-Server und mit `--permission-mode dontAsk`. Vorab erlaubt sind nur die Suche und WebFetch für diese Seiten (`--allowedTools WebSearch,WebFetch(domain:…),…`); alles andere, was eine Erlaubnis bräuchte, wird abgelehnt, etwa Read außerhalb des Chat-Ordners oder eine andere Webseite. Keine Befehle, kein Schreiben, kein Zugang zum Server; der Schlüssel des Servers erreicht Claude nicht.

Das Internet gibt es nur im eingeschränkten Modus (siehe unten): Nur dann kann Read sicher nichts außerhalb des Chat-Ordners lesen, etwa die Einstellungen des Helfers mit dem Schlüssel. Und warum nur ausgewählte Seiten: Die Suche läuft bei Anthropic, eine Seite ruft Claude dagegen vom Mac aus auf, und ihre Adresse sieht, wer die Seite betreibt. Eine Anweisung, die in einem PDF oder auf einer Webseite versteckt ist, könnte Claude sonst dazu bringen, Text aus deinen Notizen in eine solche Adresse zu packen. Was Claude sucht, sieht die Suchmaschine; Claude soll deshalb mit Begriffen und Namen suchen statt mit längeren Passagen aus dem Dokument und Text aus Webseiten oder dem Dokument nicht als Anweisung nehmen. Ganz ohne Internet: `"web": false` in den Einstellungen.

Kennt die installierte Version von Claude Code den eingeschränkten Modus (`--restricted`), läuft jede Frage darin. Dann gelten auch deine eigenen Erlaubnisse aus `~/.claude/settings.json` nicht, etwa eine Regel, die Read überall erlaubt. Ob der Modus an ist, steht beim Start im Protokoll („eingeschränkter Modus an“). Steht dort „nicht verfügbar“: `claude update` und den Helfer neu starten (Einrichten noch einmal ausführen).

Weitere Seiten eines langen PDFs liest Claude seitenweise. Dafür braucht Claude Code das Programm `pdftoppm` (`brew install poppler`); ohne bleibt es bei den Seiten um die Frage.

## Im Alltag

- Protokoll: `~/Library/Application Support/BetterNotes-Helfer/helfer.log`
- Chats ansehen und am Mac weiterfragen: `zsh native/Notizbuch/claude-fragen/chat.sh` (oder `chat.sh Analysis` für das Dokument mit „Analysis“ im Titel)
- Anhalten: `zsh native/Notizbuch/claude-fragen/entfernen.sh`

## Einstellungen

In `~/Library/Application Support/BetterNotes-Helfer/config.json`, danach den Helfer neu starten (Einrichten noch einmal ausführen):

```json
"quick":    { "effort": "medium", "model": null, "minutes": 15 },
"thorough": { "effort": "max",    "model": null, "minutes": 45 }
```

Lernwörter (für Sascha, siehe BRIEFKASTEN.md) laufen mit eigener Stufe, schnell, weil ein Kind wartet: `"lernen": { "effort": "low", "model": null, "minutes": 3 }`. Dabei bekommt Claude das Bild gleich in der Nachricht und schreibt ab, was dasteht, ohne das gesuchte Wort zu kennen (sonst würde es das richtige Wort hineinlesen). Weicht es ab, fragt die App sofort im Hintergrund nach einem Hinweis auf die Rechtschreibregel (eigene kurze Frage mit Wort und Gelesenem), während Sascha das Gelesene prüft. Ohne Internet, nur Read im Ordner des Wortes (`chats/lernwoerter/<id>`, nach 7 Tagen weg). Lernwörter kommen vor anderen Fragen dran. Setzt Sascha den Stift 0,7 s ab, schickt die App das Bild schon vorab (höchstens 3 Vorab-Fragen je Wort und Versuch); tippt er dann ohne Änderung auf „Fertig“, ist die Antwort meist schon da. Schreibt er weiter, löscht die App die Vorab-Frage und der Helfer bricht ab.

`effort` ist die Denkstufe von `claude --effort`, `model` ein Modell für `claude --model` (`null`: das Standardmodell), `minutes` die längste Zeit für eine Antwort.

`"web": false` nimmt Claude das Internet: Dann zählt nur das Dokument.

`"webSites"` sind die Seiten, die Claude ganz lesen darf: Muster wie `"arxiv.org"` oder `"*.wikipedia.org"` (alle Subdomains, etwa de.wikipedia.org). Die Liste in der Einstellungsdatei ersetzt die eingebaute (siehe `DEFAULTS` in `helfer.mjs`). `[]` heißt nur suchen, `["*"]` alle Seiten; dann gilt die Warnung oben.

`"restricted": false` schaltet den eingeschränkten Modus ab (nur nötig, falls Claude Code darin nicht antwortet); dann gibt es auch kein Internet.

## Für Entwickler

Schnittstelle am Server (alle mit `Authorization: Bearer <Schlüssel>`):

| Aufruf | Wer | Wozu |
|---|---|---|
| `PUT /api/doc/<doc>/asks/<id>` | App | neue Frage: multipart mit `meta` (JSON), `question` (PNG, beim ∞ JPEG) und `page` (JPEG/PNG), beide mit Dateinamen; dazu die Seiten um die Frage: `meta.span` [erste, letzte] (ab 0, höchstens 21 Seiten), `meta.pages` (die beschriebenen darin außer der Seite der Frage, höchstens 12) und, wenn `pages` nicht leer ist, der Teil `pages` (PDF mit Dateinamen, je Seite eine, höchstens 8 MB). Passt etwas davon nicht, gilt die Frage ohne die Seiten |
| `GET /api/doc/<doc>/asks` | App | alle Fragen des Dokuments mit Version `v` |
| `DELETE /api/doc/<doc>/asks/<id>` | App | Markierung löschen |
| `PATCH /api/doc/<doc>/asks` | App | Stellen nach Seitenänderungen: `{pv, anchors: {id: anchor oder null}}`; Seite −1 heißt: Seite gelöscht, Rückgängig noch möglich (nicht angezeigt) |
| `GET /api/asks/ws` | Helfer | WebSocket: `{"type":"ask"}` bei neuen Fragen, `{"type":"cancel","id"}` beim Löschen; `ping` → `pong` |
| `GET /api/asks/open` | Helfer | offene Fragen, `next`: Sekunden bis zur nächsten zurückgestellten |
| `POST /api/asks/<id>/claim` | Helfer | übernehmen (`{lease}`), mit `{claim}` die Frist verlängern; gibt auch `span`, `pages` und `images.pages` zurück, oder `span`/`pages` null, wenn die App sie nicht schickte oder die Seiten seither rückten (Seitenstand der Frage oder des Dokuments neuer, Frage auf einer anderen Seite) |
| `GET /api/asks/<id>/question`, `…/page`, `…/pages` | Helfer | die beiden Bilder und das PDF der Seiten um die Frage |
| `PUT /api/asks/<id>/answer` | Helfer | `{claim, markdown}`, `{claim, error}` oder `{claim, release: true, note, retryAfter}` |

Nach jeder Änderung schickt der Server den Apps mit diesem Dokument offen `{"type":"asks","v":N}`; Gäste eines geteilten Links bekommen nichts davon. Gelöschte Fragen merkt er sich 30 Tage: Lädt eine App eine davon noch einmal hoch (ihre erste Antwort ging verloren), entsteht sie nicht neu. Eine neue Frage auf einem älteren Seitenstand, als er kennt, lehnt er mit 409 `stale-pages` ab (ihre Stelle stimmt nicht mehr).

Tests (nur gegen einen lokalen Server mit Wegwerf-Schlüssel, nie gegen den echten; andere Adressen lehnen sie ab):

```sh
cd native/Notizbuch/server && npx wrangler dev --ip 127.0.0.1 --port 8791 --var SECRET:testkey --persist-to "$(mktemp -d)"
# in einem zweiten Terminal, im Ordner des Repos:
BASE=http://127.0.0.1:8791 KEY=testkey node native/Notizbuch/server/test/asks.mjs
BASE=http://127.0.0.1:8791 KEY=testkey node native/Notizbuch/claude-fragen/test/helper-test.mjs
```

`helper-test.mjs` startet den Helfer mit `test/fake-claude` statt Claude Code und `test/fake-osascript` statt macOS; sein Arbeitsordner wird nach einem erfolgreichen Lauf gelöscht (`KEEP=1` behält ihn). `fake-claude` lässt sich auch von Hand als `claude` in einer Test-`config.json` eintragen: Mit `{"mode": "rich"}` in `$FAKE_STATE/mode.json` antwortet er mit Formeln, Liste und Code, um die Karte in der App anzusehen.

## Vokabelfotos für Mios Lernkarten

Die Lernkarten-App (Web-App unter `karten/` im Repo, auf GitHub Pages) schickt Fotos von Vokabellisten an
`/api/karten/foto/<uuid>` des Notizbuch-Servers, mit einem eigenen Schlüssel, der nur dort gilt (HMAC aus dem
Server-Schlüssel, nichts einzutragen). Der Helfer nimmt sie als Frage mit effort `vokabeln` (gleich nach den
Lernwörtern), lässt Claude die Vokabeln samt Beispielsatz als JSON schreiben und antwortet damit; die App macht daraus
Karten in beide Richtungen. Einstellbar in config.json: `"vokabeln": {"effort": "medium", "minutes": 6}`.

Einrichtungslink für Mios iPhone: `zsh native/Notizbuch/claude-fragen/karten-link.sh` (legt ihn in die
Zwischenablage). In der Lernkarten-App: ⋯ → Vokabelfotos → Link einsetzen.
Test: `node server/test/karten.mjs` (Server) und `claude-fragen/test/helper-test.mjs` (Abschnitt Vokabelfotos).
