#!/bin/zsh
# Hält den Helfer für „Claude fragen“ an und startet ihn nicht mehr. Chats, Protokoll und Zugang bleiben in
# ~/Library/Application Support/BetterNotes-Helfer (zum ganz Entfernen diesen Ordner löschen).
set -euo pipefail
DEST="${BETTERNOTES_HELFER_HOME:-$HOME/Library/Application Support/BetterNotes-Helfer}"
LABEL="${BETTERNOTES_HELFER_LABEL:-local.betternotes.claude-fragen}"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
echo "Helfer angehalten. Seine Daten liegen weiter in: $DEST"
