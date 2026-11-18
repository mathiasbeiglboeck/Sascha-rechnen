# Notizbuch (native iPad- und iPhone-App)

Handschriftliche Notizen auf dünn grau kariertem A4 und Notizen auf PDFs, mit PencilKit.

- Seiten liegen untereinander und werden vertikal gescrollt; im Notizbuch kommt automatisch eine neue Seite dazu, sobald auf der letzten geschrieben wird.
- Am iPad schreibt nur der Pencil, der Finger scrollt und zoomt.
- Stift mit 5 Farben und 5 Dicken, Radierer (löscht ganze Striche), Rückgängig.
- Markdown (`.md`, über „Importieren“, „Öffnen in“ oder den Briefkasten) wird einmal auf A4-Seiten gesetzt, mit Formeln wie in
  den Antworten von „Claude fragen“; danach ist es ein PDF-Dokument wie jedes andere (der Text ist nicht bearbeitbar).
- Apple Pencil Pro: **Drücken** blendet alle Menüs aus und wieder ein, **Doppeltippen** wechselt zwischen Stift und Radierer.
- Daten: `Dokumente/Notizbuch/<id>/` mit `meta.json`, `drawing.data` (PKDrawing über alle Seiten, 768 Punkte breites Seitenkoordinatensystem) und bei PDFs `source.pdf`. Der Ordner ist in der Dateien-App unter „Auf meinem iPad > Notizbuch“ sichtbar.

Sync zwischen iPad und iPhone und der Briefkasten für KI-Agenten laufen über den Server in `server/` (Einrichtung dort im README, Nutzung in `BRIEFKASTEN.md`).

## Bauen und installieren (AltStore)
1. `./build-ipa.sh` baut `build/Notizbuch-<Nummer>.ipa` ohne Signatur. Die Versionsnummer ist die Zahl der Commits
   bis zu diesem Stand, steigt also mit jedem neuen Stand; „+“ heißt: mit ungespeicherten Änderungen an den Quellen.
2. Die .ipa mit AltServer („Sideload .ipa“) aufs iPad bzw. iPhone spielen.
3. Welche App drauf ist, steht unten in den Sync-Einstellungen (Zahnrad in der Übersicht): dieselbe Nummer, dazu
   Zeit und Kennung des Commits (bei „+“ die Zeit des Bauens). AltStore und die iPad-Einstellungen zeigen dieselbe
   Nummer als Version.

Alternativ `Notizbuch.xcodeproj` in Xcode öffnen und direkt aufs angeschlossene Gerät spielen.
