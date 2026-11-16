#!/bin/zsh
# Die Chats von „Claude fragen“ (einer je Dokument) am Mac ansehen und dort weiterschreiben.
#   zsh chat.sh             Liste der Dokumente, dann eine Nummer wählen
#   zsh chat.sh Analysis    gleich den Chat des Dokuments, dessen Titel „Analysis“ enthält
# Der Chat öffnet sich als Abzweigung: Du siehst alles bisherige und kannst weiterfragen; neue Fragen aus der
# App gehen weiter in den ursprünglichen Chat.
set -euo pipefail
DEST="${BETTERNOTES_HELFER_HOME:-$HOME/Library/Application Support/BetterNotes-Helfer}"
if [[ ! -f "$DEST/state.json" ]]; then echo "Noch keine Chats."; exit 0; fi
CLAUDE=$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).claude' "$DEST/config.json")
LIST=("${(@f)$(node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const q = (process.argv[2] || "").toLowerCase();
  for (const [id, d] of Object.entries(s.docs || {}))
    if (d.session && (d.title || "").toLowerCase().includes(q)) console.log([id, d.session, d.title || "ohne Titel"].join("\t"));
' "$DEST/state.json" "${1:-}")}")
if [[ -z ${LIST[1]:-} ]]; then echo "Kein passender Chat."; exit 0; fi
if (( ${#LIST} == 1 )); then
  PICK=1
else
  for i in {1..${#LIST}}; do print -r -- "$i  ${LIST[$i]##*$'\t'}"; done
  read "PICK?Nummer: "
fi
ENTRY=${LIST[$PICK]}
DOC=${ENTRY%%$'\t'*}
REST=${ENTRY#*$'\t'}
SESSION=${REST%%$'\t'*}
cd "$DEST/chats/$DOC"
exec "$CLAUDE" --resume "$SESSION" --fork-session
