# Notizbuch-Briefkasten (für Claude, Codex und andere Agenten)

Über den Briefkasten bekommt Mathias PDFs und Markdown direkt in seine Notizbuch-App auf iPad und iPhone, und er schickt beschriebene Seiten zurück.

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

## Markdown an die App schicken (Eingang)

Markdown (UTF-8, höchstens 512 KB) geht in denselben Eingang, mit `?type=md`:

```sh
curl -sS -X POST "$NOTIZBUCH_URL/api/inbox?type=md" \
  -H "Authorization: Bearer $NOTIZBUCH_KEY" \
  -H "Content-Type: text/markdown; charset=utf-8" \
  --data-binary @notizen.md
# → {"id":"…","title":"Erste Überschrift","source":"md"}
```

Die App setzt es einmal auf A4-Seiten, mit Formeln wie in den Antworten von „Claude fragen“ (`$…$`, `$$…$$`, `\(…\)`, `\[…\]`), und danach ist es ein Dokument wie ein PDF, auf das Mathias schreibt. Ohne `?title=` heißt es wie die erste Überschrift (`#` bis `###`). HTML und Bilder zeigt die App nicht, Text, Formeln, Listen, Tabellen, Code und Links schon. Es erscheint etwas später als ein PDF, weil erst ein Gerät mit der App es setzen muss.

Für Notizen und Antworten mit Formeln reicht Markdown, ein PDF muss dafür nicht erst gebaut werden. Ein PDF nur, wenn es schon eines gibt oder Bilder und eigenes Layout wichtig sind. Antwortet der Eingang mit „Das ist kein PDF …“, läuft dort noch ein älterer Server: dann wie bisher ein PDF schicken.

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

## Lernwörter für Sascha ablegen

Mathias' Sohn Sascha (8, Volksschule in Wien) übt in der App unter „Lernwörter üben“: Die App spricht ein Wort vor, er schreibt es, der Mac liest es und gibt Hinweise. Die Wörter kommen von Mathias, auf beliebigem Weg (Chat, Foto des Lernwörter-Blatts). Leg sie so ab:

```sh
curl -sS -X POST "$NOTIZBUCH_URL/api/lernen/woerter" \
  -H "Authorization: Bearer $NOTIZBUCH_KEY" -H "Content-Type: application/json; charset=utf-8" \
  --data '{"add":[{"wort":"Fahrrad","satz":"Ich fahre mit dem Fahrrad zur Schule."},{"wort":"Meer","satz":"Im Sommer fahren wir ans Meer."}]}'
# → {"ok":true,"added":["Fahrrad","Meer"],"removed":[],"v":…}
```

- Schreib jedes Wort genau so, wie es richtig geschrieben wird (Groß- und Kleinschreibung zählt: Hauptwörter groß).
- Gib zu jedem Wort einen kurzen, kindgerechten Satz mit, in dem das Wort genau so vorkommt. Die App spricht „Schreib das Wort: …“ und, wenn am Start „Mit Beispielsatz vorsprechen“ an ist, danach Satz und Wort. Bei gleich klingenden Wörtern (das/dass, Meer/mehr, Lid/Lied) muss der Satz zeigen, welches gemeint ist.
- Ein schon bekanntes Wort behält seinen Lernstand; neu mitgeschickter Satz ersetzt den alten. Entfernen: `{"remove":["Meer"]}`.
- Alte Wörter bleiben in der Wiederholung (Lernkartei), bis sie jemand entfernt. Höchstens 500 Wörter.

Lernstand ansehen (etwa wenn Mathias fragt, welche Wörter noch hängen):

```sh
curl -sS "$NOTIZBUCH_URL/api/lernen" -H "Authorization: Bearer $NOTIZBUCH_KEY"
# → {"v":…,"words":[{"wort","satz","added","removed"?}],"log":[{"wort","t","ergebnis":"richtig"|"zweiter"|"falsch","gelesen":[…],"wdh"?,"selbst"?}]}
```

`richtig` heißt gleich beim ersten Versuch, `zweiter` nach dem Hinweis (halb richtig), `falsch` auch beim zweiten Mal nicht; `gelesen` ist, was der Mac aus seiner Schrift gelesen hat (zeigt die typischen Fehler), `wdh` eine Wiederholung in derselben Runde, `t` Sekunden seit 1970. Fach in der Lernkartei: richtig → eins höher (neu → 2), zweiter → bleibt (neu → 1), falsch → 1; wieder dran nach 0, 1, 3, 7, 14 Tagen (Fach 1 bis 5).
