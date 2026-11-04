# Mathias' kleine Apps

Dieses Repo enthält Web-Apps (PWAs) für das iPhone, die über GitHub Pages veröffentlicht werden:
https://mathiasbeiglboeck.github.io/Sascha-rechnen/ (Groß-/Kleinschreibung beachten: das Repo heißt `Sascha-rechnen`).
Alles auf `main` ist sofort live. Es gibt keinen Build-Schritt und keine Abhängigkeiten, nur statische Dateien.

## Apps

### Saschas Rechenheft (`/`)
Rechenübungen für Sascha (8 Jahre): × ÷ (Einmaleins) und + − (zweistellig) in drei Stufen, 10 Aufgaben pro Runde,
Ziffernblock am Bildschirm, 2 Versuche pro Aufgabe. Rundenzähler und Verlauf liegen in `localStorage` (`sascha-rechenheft-v1`).
Dateien: `index.html`, `manifest.webmanifest`, `sw.js` (offline), `icon-*.png`.

### Stille – Meditation mit Gongs (`/meditation/`)
Dauer 10–120 min, Gong dazwischen (aus / alle 5–30 min), Vorlauf. 1 Gong zu Beginn, 1 je Intervall, 3 am Ende.
- iOS pausiert Web-Apps bei gesperrtem Bildschirm. Deshalb setzt die App die ganze Sitzung im Browser zu **einer MP3**
  zusammen: stumme MPEG-2-Layer-III-Frames (22050 Hz, mono, 8 kbit/s) plus vorkodierte Gong-Frames (`gong1.mp3`, `gong3.mp3`,
  64 kbit/s, ohne Bit-Reservoir), davor ein Xing-Kopf. So spielt iOS sie wie Musik weiter, auch gesperrt.
- Schalter „Hörbuch daneben“: `navigator.audioSession.type = "ambient"` mischt den Ton mit anderen Apps (z. B. Audible).
  Ambient-Ton verstummt beim Sperren und mit dem Lautlos-Schalter, darum hält ein Wake Lock den Bildschirm an.
- Die Gong-Klänge sind selbst synthetisiert (Klangschale aus unharmonischen Teiltönen) und lizenzfrei.
- Von Mathias am iPhone getestet, funktioniert (Oktober 2026).

## Hinweise für die Arbeit
- Mathias spricht Deutsch und Englisch. Die Oberflächen sind auf Deutsch.
- Mathias möchte das Handy wenig benutzen. Die Apps sollen ruhig, schlicht und ohne Ablenkung sein.
- Beim Ändern einer App die `CACHE`-Version in ihrer `sw.js` erhöhen, wenn neue Dateien dazukommen.
- Geplant: native iOS-Apps (Swift/Xcode) für Dinge, die im Browser nicht gehen. Installation mit kostenloser Apple-ID
  über AltStore (7 Tage gültig, Erneuern im selben WLAN wie der Mac). Höchstens 3 solcher Apps gleichzeitig.
