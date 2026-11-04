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
| PUT/GET | `/api/pdf/:id` | PDF eines Dokuments |
| POST | `/api/inbox?title=` | PDF in den Eingang → neues Dokument |
| GET | `/api/outbox` | Liste des Ausgangs |
| PUT/GET/DELETE | `/api/outbox/:name` | Datei im Ausgang |

Lokal testen: `echo SECRET=test > .dev.vars && npx wrangler dev`.
