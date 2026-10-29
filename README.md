# Daten für die Web-App „Liste“

`listen.json` wird von Claude geschrieben und von `/liste/` (GitHub Pages) gelesen.

- `aktuell`: id der Liste, die beim Öffnen sofort angezeigt wird
- `listen[]`: `id`, `titel`, `runde` (neuer Wert = alle Häkchen weg), `eintraege`
- Eintrag: `"Milch"` oder `{ "text": "Äpfel", "notiz": "6 Stück", "gruppe": "Obst" }`
