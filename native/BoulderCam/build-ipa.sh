#!/bin/bash
# Baut BoulderCam ohne Signatur und packt sie als .ipa für AltStore.
# AltStore signiert die App beim Installieren selbst mit deiner Apple-ID.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build
xcodebuild -project BoulderCam.xcodeproj -target BoulderCam -configuration Release -sdk iphoneos \
  SYMROOT="$PWD/build" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
mkdir -p build/Payload
cp -R build/Release-iphoneos/BoulderCam.app build/Payload/
(cd build && zip -qry BoulderCam.ipa Payload)
echo "Fertig: $PWD/build/BoulderCam.ipa"
