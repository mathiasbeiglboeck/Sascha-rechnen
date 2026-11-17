#!/bin/bash
# Baut Notizbuch ohne Signatur und packt sie als .ipa für AltStore.
# AltStore signiert die App beim Installieren selbst mit deiner Apple-ID.
set -euo pipefail
cd "$(dirname "$0")"

# Versionsnummer: die Zahl der Commits bis hierher, sie steigt also mit jedem neuen Stand; mit „+“, wenn die Quellen
# der App ungespeicherte Änderungen haben. Dazu kommen der Commit selbst und seine Zeit (bei „+“ die Zeit des Bauens).
# Die App zeigt alles unten in den Sync-Einstellungen (Zahnrad in der Übersicht), die Datei trägt die Nummer im Namen
if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
  echo "Achtung: flacher Klon, die Versionsnummer wäre zu klein. Erst git fetch --unshallow" >&2
  exit 1
fi
NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 0)
COMMIT=$(git rev-parse --short=7 HEAD 2>/dev/null || echo ohne-git)
# Neue Dateien zählen nur in Notizbuch/ (Xcode übersetzt dort jede); im Projektordner legt Xcode beim Öffnen eigene an
DIRTY=""
if [ -n "$(git status --porcelain -- Notizbuch 2>/dev/null)$(git status --porcelain --untracked-files=no -- Notizbuch.xcodeproj Info.plist 2>/dev/null)" ]; then
  DIRTY="+"
fi
DATE=$(git log -1 --format=%cd --date=format-local:'%d.%m.%Y %H:%M' 2>/dev/null || date '+%d.%m.%Y %H:%M')
if [ -n "$DIRTY" ]; then DATE=$(date '+%d.%m.%Y %H:%M'); fi

rm -rf build
xcodebuild -project Notizbuch.xcodeproj -target Notizbuch -configuration Release -sdk iphoneos \
  SYMROOT="$PWD/build" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  MARKETING_VERSION="$NUMBER" CURRENT_PROJECT_VERSION="$NUMBER" build
mkdir -p build/Payload
cp -R build/Release-iphoneos/Notizbuch.app build/Payload/
# Erst nach dem Bauen eintragen: Die App ist hier noch nicht signiert (das macht AltStore beim Installieren)
plutil -insert BNCommit -string "$COMMIT$DIRTY" build/Payload/Notizbuch.app/Info.plist
plutil -insert BNDate -string "$DATE" build/Payload/Notizbuch.app/Info.plist
IPA="Notizbuch-$NUMBER$DIRTY.ipa"
(cd build && zip -qry "$IPA" Payload)
echo "Fertig: $PWD/build/$IPA (Version $NUMBER$DIRTY, Commit $COMMIT vom $DATE)"
