# „Claude fragen“: der Helfer am Mac

In der Notizbuch-App eine handgeschriebene Frage mit dem Lasso markieren und im Menü **Claude fragen** (knapp) oder **Claude gründlich fragen** wählen. Neben der Frage erscheint eine Sprechblase. Ist die Antwort da, wird sie blau; antippen zeigt die Antwort mit Formeln. Dort lässt sich die Markierung auch wieder löschen, auf allen Geräten. Die Markierungen gibt es nur in der App, nicht im PDF, nicht im Export und nicht im geteilten Link.

Beantwortet wird am Mac: Dieser Helfer läuft dort im Hintergrund und bekommt jede neue Frage sofort vom Notizbuch-Server gemeldet. Er fragt Claude Code (`claude -p`) mit dem Bild der Frage, der ganzen Seite und, bei PDFs, dem Dokument. Bei einem PDF mit mehr als 10 Seiten bekommt Claude zuerst die Seiten um die Frage als eigenes kleines PDF (bei „Claude fragen“ drei davor und eine danach, gründlich sieben davor und zwei danach); das ganze PDF liegt daneben. Je Dokument gibt es einen eigenen Chat, der mit jeder Frage weitergeht: Claude kennt die früheren Fragen zum selben Dokument.

Ist der Mac aus oder im Ruhezustand, warten die Fragen am Server und werden beantwortet, sobald er wieder läuft. Ist das Nutzungslimit von Claude erreicht, zeigt die App das an, und der Helfer versucht es später wieder.

## Einrichten

Einmal im Terminal, im Ordner des Repos:

```sh
zsh native/Notizbuch/claude-fragen/einrichten.sh
```

Das Skript braucht `node` (am besten 22 oder neuer) und `claude`. URL und Schlüssel des Servers liest es aus `~/Documents/ClaudeCode/Sascha/notizbuch-zugang.txt` und legt sie nur in der Einstellungsdatei des Helfers ab. Nach einem Update des Repos dasselbe Skript noch einmal ausführen.

Der Server muss die Fragen schon kennen (Server-Update). Sonst steht im Protokoll „Server-Update nötig“, und der Helfer wartet.

## Was Claude dabei darf

Nur lesen, und nur im Ordner des Dokuments (`chats/<Dokument>` im Ordner des Helfers, mit den Bildern der Fragen und dem PDF). Claude Code läuft dafür mit dem einzigen Werkzeug Read, ohne MCP-Server und mit `--permission-mode dontAsk`: Alles, was eine Erlaubnis bräuchte, wird abgelehnt. Keine Befehle, kein Schreiben, kein Internet, kein Zugang zum Server; der Schlüssel des Servers erreicht Claude nicht.

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

`effort` ist die Denkstufe von `claude --effort`, `model` ein Modell für `claude --model` (`null`: das Standardmodell), `minutes` die längste Zeit für eine Antwort.

`"restricted": false` schaltet den eingeschränkten Modus ab (nur nötig, falls Claude Code darin nicht antwortet).

## Für Entwickler

Schnittstelle am Server (alle mit `Authorization: Bearer <Schlüssel>`):

| Aufruf | Wer | Wozu |
|---|---|---|
| `PUT /api/doc/<doc>/asks/<id>` | App | neue Frage: multipart mit `meta` (JSON), `question` (PNG) und `page` (JPEG/PNG), beide mit Dateinamen |
| `GET /api/doc/<doc>/asks` | App | alle Fragen des Dokuments mit Version `v` |
| `DELETE /api/doc/<doc>/asks/<id>` | App | Markierung löschen |
| `PATCH /api/doc/<doc>/asks` | App | Stellen nach Seitenänderungen: `{pv, anchors: {id: anchor oder null}}`; Seite −1 heißt: Seite gelöscht, Rückgängig noch möglich (nicht angezeigt) |
| `GET /api/asks/ws` | Helfer | WebSocket: `{"type":"ask"}` bei neuen Fragen, `{"type":"cancel","id"}` beim Löschen; `ping` → `pong` |
| `GET /api/asks/open` | Helfer | offene Fragen, `next`: Sekunden bis zur nächsten zurückgestellten |
| `POST /api/asks/<id>/claim` | Helfer | übernehmen (`{lease}`), mit `{claim}` die Frist verlängern |
| `GET /api/asks/<id>/question`, `…/page` | Helfer | die beiden Bilder |
| `PUT /api/asks/<id>/answer` | Helfer | `{claim, markdown}`, `{claim, error}` oder `{claim, release: true, note, retryAfter}` |

Nach jeder Änderung schickt der Server den Apps mit diesem Dokument offen `{"type":"asks","v":N}`; Gäste eines geteilten Links bekommen nichts davon.

Tests (nur gegen einen lokalen Server mit Wegwerf-Schlüssel, nie gegen den echten):

```sh
cd native/Notizbuch/server && npx wrangler dev --ip 127.0.0.1 --port 8791 --var SECRET:testkey --persist-to "$(mktemp -d)"
# in einem zweiten Terminal, im Ordner des Repos:
BASE=http://127.0.0.1:8791 KEY=testkey node native/Notizbuch/server/test/asks.mjs
BASE=http://127.0.0.1:8791 KEY=testkey node native/Notizbuch/claude-fragen/test/helper-test.mjs
```

`helper-test.mjs` startet den Helfer mit `test/fake-claude` statt Claude Code und `test/fake-osascript` statt macOS. `fake-claude` lässt sich auch von Hand als `claude` in einer Test-`config.json` eintragen: Mit `{"mode": "rich"}` in `$FAKE_STATE/mode.json` antwortet er mit Formeln, Liste und Code, um die Karte in der App anzusehen.
