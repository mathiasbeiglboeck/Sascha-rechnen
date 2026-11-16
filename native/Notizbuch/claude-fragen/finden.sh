# Für einrichten.sh und chat.sh (mit source): node und Claude Code am Mac finden, auch wenn sie nicht im PATH stehen.

# node: im PATH, sonst die Kopie in Sascha/.notizbuch-tools (neueste Version), sonst Homebrew
finde_node() {
  local c
  for c in ${commands[node]:-} \
      "$HOME/Documents/ClaudeCode/Sascha/.notizbuch-tools"/node-*/bin/node(NnOn) \
      /opt/homebrew/bin/node /usr/local/bin/node; do
    if [[ -x $c ]]; then print -r -- ${c:A}; return 0; fi
  done
  return 1
}

# Claude Code fürs Terminal: im PATH oder an den üblichen Orten (der Pfad bleibt bei Updates gleich)
finde_claude() {
  local c
  for c in ${commands[claude]:-} "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" \
      /opt/homebrew/bin/claude /usr/local/bin/claude; do
    if [[ -x $c ]]; then print -r -- $c; return 0; fi
  done
  return 1
}

# Die Kopie von Claude Code in der Claude-App, neueste Version. Ihr Pfad ändert sich mit jedem Update der App, und
# allein gestartet ist sie nur angemeldet, wenn man sich damit einmal selbst angemeldet hat
finde_app_claude() {
  local c
  for c in "$HOME/Library/Application Support/Claude/claude-code"/*/*/claude.app/Contents/MacOS/claude(NnOn); do
    if [[ -x $c ]]; then print -r -- $c; return 0; fi
  done
  return 1
}
