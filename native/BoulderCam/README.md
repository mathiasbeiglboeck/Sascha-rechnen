# BoulderCam (native iPhone-App)

Kamera zum Selbstfilmen beim Bouldern: Handy aufstellen, klettern, abspringen und den Versuch verzögert anschauen.

- Großes Bild: die Frontkamera **verzögert** (20 s bis 2 min, Standard 40 s), ungespiegelt wie ein abgespieltes Video. Gewählt wird das Kameraformat mit dem größten Bildausschnitt (4:3 bei den meisten iPhones), Bildstabilisierung, Center Stage und Verzeichnungskorrektur sind aus.
- **Lauter / Leiser** verlängert bzw. verkürzt die Verzögerung (5-s-Schritte bis 1 min, darüber 10 s); der neue Wert blitzt groß auf.
- Klein unten links: das **Live-Bild**, gespiegelt wie bei einer normalen Selfie-Kamera, zum Ausrichten.
- **Aufnahmeknopf**: nimmt das verzögerte Video ab der Stelle auf, die beim Drücken gezeigt wird, bis zur Stelle beim zweiten Drücken; das Video (mit Ton, ohne neu zu kodieren) kommt in Fotos.
- Die letzten 2 min 10 s liegen als H.264 im Speicher (etwa 1 MB pro Sekunde), nichts landet ungefragt auf dem Gerät.
- Kamerawechsel auf die hintere Ultraweitwinkel-Kamera oben rechts.
- Die Bilder werden immer hochkant gespeichert; steht das Handy quer, bekommt die Datei eine Drehung mit, damit Fotos sie richtig zeigt.

Braucht iOS 17.2 (Lautstärketasten über `AVCaptureEventInteraction`).

## Aufbau
- `CameraEngine.swift`: Kamera, Ringpuffer, verzögerte Wiedergabe (`AVSampleBufferDisplayLayer` mit eigener Zeitbasis, die um die Verzögerung hinter dem neuesten Bild läuft), Aufnahme der Wiederholung.
- `VideoEncoder.swift`: H.264-Kodierer (VideoToolbox, Schlüsselbild jede Sekunde).
- `ClipWriter.swift`: schreibt die schon kodierten Bilder plus Ton in eine .mov und legt sie in Fotos ab.
- `CameraView.swift` (Wiedergabe mit Lautstärketasten, Live-Bild), `BoulderCamApp.swift`: Oberfläche.

## Bauen und installieren
1. `./build-ipa.sh` baut `build/BoulderCam.ipa` ohne Signatur.
2. Mit AltServer („Sideload .ipa“) aufs iPhone spielen, oder `BoulderCam.xcodeproj` in Xcode öffnen und direkt aufs Gerät spielen.
