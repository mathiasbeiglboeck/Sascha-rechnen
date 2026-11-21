# BoulderCam (native iPhone-App)

Kamera zum Selbstfilmen beim Bouldern: Handy aufstellen, klettern, abspringen und den Versuch verzögert anschauen.

- Frontkamera (Umschalten auf die hintere Ultraweitwinkel-Kamera möglich), 4:3, Bildstabilisierung und Center Stage aus, immer das ganze Bild.
- Bild normal oder gespiegelt (pro Kamera gemerkt).
- Wiedergabe **live** oder **verzögert** (5 s bis 2 min, Standard 1 min). Doppeltipp aufs Bild wechselt zwischen live und der zuletzt gewählten Verzögerung.
- Die letzten Minuten liegen als H.264 im Speicher (Verzögerung + 40 s, etwa 1 MB pro Sekunde), nichts landet ungefragt auf dem Gerät.
- **Lautstärketaste** (oder der große Knopf):
  - live: Aufnahme starten und stoppen, das Video kommt in Fotos;
  - verzögert: speichert die Wiederholung in Fotos, und zwar ab 30 s vor der gerade gezeigten Stelle bis jetzt (ohne neu zu kodieren);
  - während einer Aufnahme: Aufnahme beenden.
- Die Bilder werden immer hochkant gespeichert; steht das Handy quer, bekommt die Datei eine Drehung mit, damit Fotos sie richtig zeigt.

Braucht iOS 17.2 (Lautstärketasten über `AVCaptureEventInteraction`).

## Aufbau
- `CameraEngine.swift`: Kamera, Ringpuffer, verzögerte Wiedergabe (`AVSampleBufferDisplayLayer` mit eigener Zeitbasis, die um die Verzögerung hinter dem neuesten Bild läuft), Aufnahme, Speichern.
- `VideoEncoder.swift`: H.264-Kodierer (VideoToolbox, Schlüsselbild jede Sekunde).
- `ClipWriter.swift`: schreibt die schon kodierten Bilder plus Ton in eine .mov und legt sie in Fotos ab.
- `CameraView.swift`, `BoulderCamApp.swift`: Oberfläche.

## Bauen und installieren
1. `./build-ipa.sh` baut `build/BoulderCam.ipa` ohne Signatur.
2. Mit AltServer („Sideload .ipa“) aufs iPhone spielen, oder `BoulderCam.xcodeproj` in Xcode öffnen und direkt aufs Gerät spielen.
