# Notizbuch (native iPad- und iPhone-App)

Handschriftliche Notizen auf dünn grau kariertem A4 und Notizen auf PDFs, mit PencilKit.

- Seiten liegen untereinander und werden vertikal gescrollt; im Notizbuch kommt automatisch eine neue Seite dazu, sobald auf der letzten geschrieben wird.
- Am iPad schreibt nur der Pencil, der Finger scrollt und zoomt.
- Stift mit 5 Farben und 5 Dicken, Radierer (löscht ganze Striche), Rückgängig.
- Apple Pencil Pro: **Drücken** blendet alle Menüs aus und wieder ein, **Doppeltippen** wechselt zwischen Stift und Radierer.
- Daten: `Dokumente/Notizbuch/<id>/` mit `meta.json`, `drawing.data` (PKDrawing über alle Seiten, 768 Punkte breites Seitenkoordinatensystem) und bei PDFs `source.pdf`. Der Ordner ist in der Dateien-App unter „Auf meinem iPad > Notizbuch“ sichtbar.

Sync zwischen iPad und iPhone und der Briefkasten für KI-Agenten laufen über den Server in `server/` (Einrichtung dort im README, Nutzung in `BRIEFKASTEN.md`).

## Bauen und installieren (AltStore)
1. `./build-ipa.sh` baut `build/Notizbuch.ipa` ohne Signatur.
2. Die .ipa mit AltServer („Sideload .ipa“) aufs iPad bzw. iPhone spielen.

Alternativ `Notizbuch.xcodeproj` in Xcode öffnen und direkt aufs angeschlossene Gerät spielen.
