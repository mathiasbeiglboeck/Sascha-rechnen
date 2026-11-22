#!/bin/zsh
# Einrichtungslink für Mios Lernkarten-App (Vokabelfotos). Im Terminal ausführen:
#   zsh native/Notizbuch/claude-fragen/karten-link.sh
#
# Liest URL und Schlüssel aus der config.json des Helfers (einrichten.sh muss vorher gelaufen sein) und rechnet daraus
# den Lernkarten-Schlüssel (HMAC, wie der Server). Der darf nur Vokabelfotos schicken, nicht ins Notizbuch.
# Der Link landet in der Zwischenablage; schick ihn an Mios iPhone (etwa per AirDrop oder Nachricht) und öffne ihn
# dort in der installierten App: Einstellungen (⋯) → „Fotos einrichten“ → Link einsetzen.
set -euo pipefail
HERE=${0:A:h}
CONF="${BETTERNOTES_HELFER_HOME:-$HOME/Library/Application Support/BetterNotes-Helfer}/config.json"
source "$HERE/finden.sh"
NODE=$(finde_node || true)
if [[ -z $NODE ]]; then echo "Node.js nicht gefunden (node)."; exit 1; fi
if [[ ! -f $CONF ]]; then echo "Keine config.json des Helfers. Zuerst einrichten.sh ausführen."; exit 1; fi
LINK=$("$NODE" -e '
const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const k = require("crypto").createHmac("sha256", c.key).update("lernkarten-foto").digest("base64url").slice(0, 32);
const code = Buffer.from(JSON.stringify({ u: String(c.url).replace(/\/+$/, ""), k })).toString("base64url");
console.log("https://mathiasbeiglboeck.github.io/Sascha-rechnen/karten/#foto=" + code);
' "$CONF")
print -rn -- "$LINK" | pbcopy
echo "Der Einrichtungslink für die Lernkarten ist in der Zwischenablage."
