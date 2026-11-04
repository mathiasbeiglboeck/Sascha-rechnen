# Notizbuch-Briefkasten (für Claude, Codex und andere Agenten)

Über den Briefkasten bekommt Mathias PDFs direkt in seine Notizbuch-App auf iPad und iPhone, und er schickt beschriebene Seiten zurück.

Du brauchst zwei Werte von Mathias. Schreib sie nie ins Repo:
- `NOTIZBUCH_URL`, zum Beispiel `https://notizbuch.<name>.workers.dev`
- `NOTIZBUCH_KEY`, den geheimen Schlüssel

Alle Aufrufe brauchen den Header `Authorization: Bearer $NOTIZBUCH_KEY`.

## PDF an die App schicken (Eingang)

```sh
curl -sS -X POST "$NOTIZBUCH_URL/api/inbox?title=Übungsblatt%203" \
  -H "Authorization: Bearer $NOTIZBUCH_KEY" \
  --data-binary @blatt.pdf
# → {"id":"…","title":"Übungsblatt 3"}
```

Das PDF erscheint innerhalb von etwa 20 Sekunden als neues Dokument in der Übersicht der App.

## Zurückgeschickte Seiten abholen (Ausgang)

Der Ausgang ist nach Empfänger getrennt. In der App wählt Mathias im Teilen-Menü „Seite an Claude senden“ oder „Seite an ChatGPT senden“. Eine einzelne Seite kommt als `<Titel> – Seite N.pdf` und als `.png`, ein ganzes Dokument („Ganzes Dokument“, höchstens 80 Seiten) als `<Titel>.pdf` bzw. `<Titel> – Seiten 1-80.pdf` in den Ordner dieses Empfängers.

**Hole nur aus deinem eigenen Ordner:** Claude nimmt `claude`, ChatGPT/Codex nimmt `chatgpt`.

```sh
TO=claude   # oder chatgpt
# Liste, neueste zuerst
curl -sS "$NOTIZBUCH_URL/api/outbox/$TO" -H "Authorization: Bearer $NOTIZBUCH_KEY"
# → {"files":[{"to":"claude","name":"Übungsblatt 3 – Seite 1.png","size":…,"type":"image/png","created":…}, …]}

# Eine Datei laden (Name URL-kodieren)
curl -sS "$NOTIZBUCH_URL/api/outbox/$TO/<name>" -H "Authorization: Bearer $NOTIZBUCH_KEY" -o seite.png

# Danach aufräumen
curl -sS -X DELETE "$NOTIZBUCH_URL/api/outbox/$TO/<name>" -H "Authorization: Bearer $NOTIZBUCH_KEY"
```

Das PNG eignet sich zum Ansehen der Handschrift, das PDF zum Weitergeben. Wenn Mathias sagt „schau in den Ausgang“ oder „ich hab dir eine Seite geschickt“, ist die neueste Datei in deinem Ordner gemeint.

Hinweis für Cloud-Agenten: Die Netzwerk-Freigabe der Umgebung muss den Host von `NOTIZBUCH_URL` erlauben (`*.workers.dev`).
