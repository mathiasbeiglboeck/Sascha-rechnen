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

In der App: Teilen-Knopf, dann „Seite an KI senden“. Jede Seite kommt als `<Titel> – Seite N.pdf` und als `.png` in den Ausgang.

```sh
# Liste, neueste zuerst
curl -sS "$NOTIZBUCH_URL/api/outbox" -H "Authorization: Bearer $NOTIZBUCH_KEY"
# → {"files":[{"name":"Übungsblatt 3 – Seite 1.png","size":…,"type":"image/png","created":…}, …]}

# Eine Datei laden (Name URL-kodieren)
curl -sS "$NOTIZBUCH_URL/api/outbox/<name>" -H "Authorization: Bearer $NOTIZBUCH_KEY" -o seite.png

# Danach aufräumen
curl -sS -X DELETE "$NOTIZBUCH_URL/api/outbox/<name>" -H "Authorization: Bearer $NOTIZBUCH_KEY"
```

Das PNG eignet sich zum Ansehen der Handschrift, das PDF zum Weitergeben.

Hinweis für Cloud-Agenten: Die Netzwerk-Freigabe der Umgebung muss den Host von `NOTIZBUCH_URL` erlauben (`*.workers.dev`).
