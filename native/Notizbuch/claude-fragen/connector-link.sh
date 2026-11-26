#!/bin/zsh
# Adresse des Notizbuch-Connectors für claude.ai. Im Terminal ausführen:
#   zsh native/Notizbuch/claude-fragen/connector-link.sh
#
# Liest URL und Schlüssel aus der config.json des Helfers (einrichten.sh muss vorher gelaufen sein) und rechnet daraus
# den Connector-Schlüssel (HMAC, wie mcpKey im Server, src/mcp.js). Die Adresse landet in der Zwischenablage; in claude.ai
# unter Einstellungen → Connectors → „Benutzerdefinierten Connector hinzufügen“ als URL einsetzen.
# Sie ist ein Zugang zum Briefkasten des Notizbuchs: nicht in Chats, Dateien oder Repos schreiben.
# Ist auf dem Server MCP_VERSION gesetzt (zum Sperren einer alten Adresse), denselben Wert hier mitgeben:
#   MCP_VERSION=2 zsh native/Notizbuch/claude-fragen/connector-link.sh
set -euo pipefail
HERE=${0:A:h}
CONF="${BETTERNOTES_HELFER_HOME:-$HOME/Library/Application Support/BetterNotes-Helfer}/config.json"
source "$HERE/finden.sh"
NODE=$(finde_node || true)
if [[ -z $NODE ]]; then echo "Node.js nicht gefunden (node)."; exit 1; fi
if [[ ! -f $CONF ]]; then echo "Keine config.json des Helfers. Zuerst einrichten.sh ausführen."; exit 1; fi
LINK=$(MCP_VERSION="${MCP_VERSION:-}" "$NODE" -e '
const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const v = process.env.MCP_VERSION;
const k = require("crypto").createHmac("sha256", c.key).update("mcp-connector" + (v ? ":" + v : "")).digest("base64url").slice(0, 32);
console.log(String(c.url).replace(/\/+$/, "") + "/mcp/" + k);
' "$CONF")
print -rn -- "$LINK" | pbcopy
if curl -sS -m 15 -X POST "$LINK" -H "content-type: application/json" \
     --data '{"jsonrpc":"2.0","id":1,"method":"ping"}' 2>/dev/null | grep -q '"result"'; then
  echo "Die Connector-Adresse ist in der Zwischenablage, und der Server antwortet darauf."
else
  echo "Die Connector-Adresse ist in der Zwischenablage, aber der Server antwortet noch nicht darauf."
  echo "Läuft schon der neue Server? (notizbuch-server-aktualisieren.sh mit dem Zweig, der den Connector hat)"
fi
