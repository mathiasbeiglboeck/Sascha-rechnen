# Notizbuch-Server (Cloudflare Workers, Gratis-Tarif)

Ein Worker mit einem Durable Object (SQLite). Er hält die Dokumente, Striche und PDFs für den Sync zwischen den Geräten und den Briefkasten (siehe `../BRIEFKASTEN.md`).

## Einmal einrichten

```sh
cd native/Notizbuch/server
npm install
npx wrangler login                 # öffnet den Browser, bei Cloudflare zustimmen
npx wrangler deploy                # zeigt die Adresse https://notizbuch.<name>.workers.dev
openssl rand -hex 24 | tee /dev/stderr | npx wrangler secret put SECRET   # Schlüssel erzeugen und setzen
```

Adresse und Schlüssel trägst du dann in der App ein (Zahnrad in der Übersicht), auf iPad und iPhone gleich.

## API

| Methode | Pfad | Zweck |
|---|---|---|
| GET | `/api/library` | alle Dokumente (mit `strokeSeq`, `hasPDF`, Grabsteinen `deleted`) |
| PUT | `/api/library/:id` | Metadaten, letzte Änderung (`modified`, Sekunden seit 1970) gewinnt |
| POST | `/api/doc/:id/sync` | `{since, add:[{id,data}], remove:[id]}` → `{seq, changes:[{id,data\|null}]}` |
| GET | `/api/doc/:id/strokes?since=&limit=&lite=1` | nur lesen (Helfer am Mac, weitere Seiten zum Nachlesen): Striche nach `since` → `{top, low, last, more, meta, changes:[{id,seq,data\|null}]}`; höchstens `limit` (1–1000, ohne Angabe 500) und 1.000.000 Zeichen, mindestens einer; weiter ab `last`, solange `more`; `lite=1` ohne `pk`; `since > 0` und `low > since` (oder `top < since`): Striche seit `since` gelöscht (Dokument gelöscht und wieder angelegt), ab 0 neu holen; `meta`: `{kind, pageCount, pagesVersion, pdfVersion, layoutVersion, deleted}` oder `null` |
| PUT/GET | `/api/pdf/:id` | PDF eines Dokuments; `PUT …?ifMissing=1` legt es nur ab, wenn noch keines da ist (`{ok}`, sonst `{exists}` bzw. `{gone}`) |
| POST | `/api/inbox?title=` | PDF in den Eingang → neues Dokument |
| POST | `/api/inbox?type=md&title=` | Markdown (UTF-8, bis 512 KB) in den Eingang → PDF-Dokument mit `source: "md"` ohne PDF; das erste Gerät mit neuer App setzt es und legt das PDF mit `ifMissing=1` ab |
| GET | `/api/md/:id` | Markdown eines solchen Dokuments |
| GET | `/api/outbox` bzw. `/api/outbox/:to` | Liste des Ausgangs (alle bzw. `claude` oder `chatgpt`) |
| PUT/GET/DELETE | `/api/outbox/:to/:name` | Datei im Ausgang eines Empfängers |
| POST/DELETE | `/api/share/:id` | Link für Gäste erzeugen (`{token}`) bzw. Teilen beenden |
| GET (WebSocket) | `/api/doc/:id/ws` | Live-Verbindung der App (Änderungen, Gäste, Ansicht) |
| GET | `/s/:token` | Web-Ansicht für Gäste (ohne Schlüssel; dazu `/s/:token/data`, `/pdf`, `/ws`) |

Lokal testen: `echo SECRET=test > .dev.vars && npx wrangler dev`.
