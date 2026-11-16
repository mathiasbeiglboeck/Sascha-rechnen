#!/bin/zsh
# Richtet den Helfer für „Claude fragen“ am Mac ein, oder aktualisiert ihn. Einfach im Terminal ausführen:
#   zsh native/Notizbuch/claude-fragen/einrichten.sh
#
# Der Helfer läuft danach im Hintergrund (launchd), auch nach einem Neustart des Macs. URL und Schlüssel des
# Notizbuch-Servers liest das Skript beim ersten Mal aus notizbuch-zugang.txt und legt sie nur in der
# config.json des Helfers ab (Rechte 600). Sie werden nirgends ausgegeben.
set -euo pipefail

HERE=${0:A:h}
# Ordner und Name des Helfers (anders nur für Tests)
DEST="${BETTERNOTES_HELFER_HOME:-$HOME/Library/Application Support/BetterNotes-Helfer}"
LABEL="${BETTERNOTES_HELFER_LABEL:-local.betternotes.claude-fragen}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
ZUGANG="${NOTIZBUCH_ZUGANG:-$HOME/Documents/ClaudeCode/Sascha/notizbuch-zugang.txt}"

source "$HERE/finden.sh"
NODE=$(finde_node || true)
if [[ -z $NODE ]]; then echo "Node.js nicht gefunden (node)."; exit 1; fi
# Claude Code: am besten fürs Terminal installiert und dort angemeldet. Sonst nimmt der Helfer die Kopie aus der
# Claude-App (er sucht sie vor jeder Frage selbst); die muss aber einmal selbst angemeldet werden
CLAUDE=$(finde_claude || true)
if [[ -z $CLAUDE ]]; then
  if finde_app_claude >/dev/null; then
    echo "Hinweis: Claude Code gibt es hier nur in der Claude-App. Der Helfer nimmt diese Kopie, allein gestartet ist"
    echo "sie aber erst angemeldet, wenn du dich damit einmal anmeldest. Einfacher: Claude Code fürs Terminal"
    echo "installieren und anmelden (siehe README)."
  else
    echo "Hinweis: Claude Code nicht gefunden. Der Helfer wartet, bis es installiert und angemeldet ist (siehe README)."
  fi
fi
NODE_MAJOR=$("$NODE" -p 'process.versions.node.split(".")[0]')
if (( NODE_MAJOR < 18 )); then echo "Node $NODE_MAJOR ist zu alt, nötig ist 18 oder neuer."; exit 1; fi
if (( NODE_MAJOR < 22 )); then
  echo "Hinweis: Node $NODE_MAJOR kann keinen WebSocket. Neue Fragen kommen dann erst nach bis zu 30 Sekunden an."
  echo "Mit Node 22 oder neuer kommen sie sofort an."
fi

mkdir -p "$DEST"
chmod 700 "$DEST"
cp "$HERE/helfer.mjs" "$DEST/helfer.mjs"

if [[ ! -f "$DEST/config.json" ]]; then
  # URL und Schlüssel aus der Zugangsdatei, ohne sie auszugeben. Gelingt das nicht, fragt das Skript danach.
  umask 077
  if [[ -f $ZUGANG ]]; then
    NOTIZBUCH_CLAUDE="$CLAUDE" "$NODE" - "$ZUGANG" "$DEST/config.json" <<'JS' || true
const fs = require("fs");
const [file, out] = process.argv.slice(2);
const text = fs.readFileSync(file, "utf8");
const found = text.match(/https:\/\/[^\s"'<>]*workers\.dev[^\s"'<>]*/) || text.match(/https?:\/\/[^\s"'<>]+/);
const url = found ? new URL(found[0]).origin : null;
const key = (text.match(/NOTIZBUCH_KEY\s*[=:]\s*["']?([^\s"']+)/) ||
  text.match(/(?:schl(?:ü|ue)ssel|key|secret)[^\n:=]*[:=]\s*["']?([^\s"']{16,})/i) || [])[1];
if (!url || !key) process.exit(1);
fs.writeFileSync(out, JSON.stringify({ url, key, claude: process.env.NOTIZBUCH_CLAUDE || undefined }, null, 2),
  { mode: 0o600 });
JS
  fi
  if [[ ! -f "$DEST/config.json" ]]; then
    echo "URL und Schlüssel des Notizbuch-Servers (stehen in notizbuch-zugang.txt):"
    read "URL?URL (https://…): "
    read -s "KEY?Schlüssel (wird nicht angezeigt): "
    echo
    NOTIZBUCH_URL_IN="$URL" NOTIZBUCH_KEY_IN="$KEY" NOTIZBUCH_CLAUDE="$CLAUDE" "$NODE" -e '
      require("fs").writeFileSync(process.argv[1], JSON.stringify({ url: process.env.NOTIZBUCH_URL_IN.trim().replace(/\/+$/, ""),
        key: process.env.NOTIZBUCH_KEY_IN.trim(), claude: process.env.NOTIZBUCH_CLAUDE || undefined }, null, 2), { mode: 0o600 });' \
      "$DEST/config.json"
    unset KEY
  fi
  echo "Zugang eingetragen."
else
  # Nur den Pfad zu claude auffrischen (ohne Pfad sucht der Helfer selbst)
  NOTIZBUCH_CLAUDE="$CLAUDE" "$NODE" -e '
    const fs = require("fs"), f = process.argv[1], c = JSON.parse(fs.readFileSync(f, "utf8"));
    if (process.env.NOTIZBUCH_CLAUDE) c.claude = process.env.NOTIZBUCH_CLAUDE; else delete c.claude;
    fs.writeFileSync(f, JSON.stringify(c, null, 2), { mode: 0o600 });' "$DEST/config.json"
fi
chmod 600 "$DEST/config.json"

# launchd: beim Anmelden starten, nach einem Absturz neu starten
mkdir -p "$HOME/Library/LaunchAgents"
SEARCH="${NODE:h}:${CLAUDE:+${CLAUDE:h}:}$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE</string>
    <string>$DEST/helfer.mjs</string>
  </array>
  <key>WorkingDirectory</key><string>$DEST</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$SEARCH</string>
    <key>HOME</key><string>$HOME</string>
    <key>BETTERNOTES_HELFER_HOME</key><string>$DEST</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>ProcessType</key><string>Standard</string>
  <key>StandardOutPath</key><string>$DEST/launchd.log</string>
  <key>StandardErrorPath</key><string>$DEST/launchd.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$UID" "$PLIST"
echo "Helfer läuft. Letzte Zeilen aus seinem Protokoll:"
sleep 4
tail -n 5 "$DEST/helfer.log" 2>/dev/null || echo "(noch nichts)"
echo
echo "Protokoll: $DEST/helfer.log"
echo "Chats ansehen und weiterschreiben: zsh ${HERE}/chat.sh"
