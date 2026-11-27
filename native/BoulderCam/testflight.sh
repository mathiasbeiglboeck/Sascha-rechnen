#!/bin/bash
# Baut BoulderCam für App Store Connect (TestFlight) mit Mathias' Team.
#   ./testflight.sh export   Archiv + signierte .ipa (legt dabei Bundle-ID und
#                            Verteilungsprofil im Entwicklerkonto an), kein Upload
#   ./testflight.sh upload   Archiv + Upload zu App Store Connect
# Die Build-Nummer ist die Zahl der Commits im Repo (steigt immer).
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-export}"
TEAM=R5W5PMUZKF
BUILD=$(git rev-list --count HEAD)
case "$MODE" in
  export) DEST=export ;;
  upload) DEST=upload ;;
  *) echo "Aufruf: $0 export|upload"; exit 1 ;;
esac
rm -rf build/archive build/export
mkdir -p build
cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>$DEST</string>
	<key>teamID</key><string>$TEAM</string>
	<key>signingStyle</key><string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key><false/>
	<key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST
xcodebuild -project BoulderCam.xcodeproj -scheme BoulderCam -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/archive/BoulderCam.xcarchive \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=$TEAM CODE_SIGN_STYLE=Automatic \
  MARKETING_VERSION=1.0 CURRENT_PROJECT_VERSION=$BUILD archive
xcodebuild -exportArchive -archivePath build/archive/BoulderCam.xcarchive \
  -exportOptionsPlist build/ExportOptions.plist -exportPath build/export -allowProvisioningUpdates
echo "Fertig ($MODE), Version 1.0 Build $BUILD"
