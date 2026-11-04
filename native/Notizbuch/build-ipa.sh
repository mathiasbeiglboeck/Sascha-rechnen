#!/bin/bash
# Baut Notizbuch ohne Signatur und packt sie als .ipa für AltStore.
# AltStore signiert die App beim Installieren selbst mit deiner Apple-ID.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build
xcodebuild -project Notizbuch.xcodeproj -target Notizbuch -configuration Release -sdk iphoneos \
  SYMROOT="$PWD/build" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
mkdir -p build/Payload
cp -R build/Release-iphoneos/Notizbuch.app build/Payload/
(cd build && zip -qry Notizbuch.ipa Payload)
echo "Fertig: $PWD/build/Notizbuch.ipa"
