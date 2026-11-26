#!/bin/bash
# isra build helper (macOS, Xcode). No make, no SwiftGen needed.
#
#   isra/build.sh generate   Info.plist copy + MC1.xcodeproj from isra.yml
#   isra/build.sh sim        build for the iOS simulator (no signing)
#   isra/build.sh phone      build signed with your Apple ID and install on the
#                            iPhone connected by cable (also the weekly re-sign
#                            for a free account: same bundle ID, data is kept)
#
# Signing: dev.yml (gitignored) holds your team ID:
#   settings:
#     base:
#       DEVELOPMENT_TEAM: ABCDE12345
set -euo pipefail
cd "$(dirname "$0")/.."
DD=isra/build/dd

generate() {
  [ -f dev.yml ] || printf 'settings:\n  base:\n    DEVELOPMENT_TEAM: ""\n' > dev.yml
  isra/make-plist.sh
  xcodegen generate --spec isra.yml
}

case "${1:-}" in
  generate) generate ;;
  sim)
    generate
    xcodebuild -project MC1.xcodeproj -scheme MC1 -configuration Debug \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" \
      CODE_SIGNING_ALLOWED=NO build | tail -3
    ;;
  phone)
    generate
    if ! grep -qE 'DEVELOPMENT_TEAM: *[A-Z0-9]{10}' dev.yml; then
      echo "dev.yml has no DEVELOPMENT_TEAM (Xcode > Settings > Accounts > your Personal Team ID)"; exit 1
    fi
    J=$(mktemp); xcrun devicectl list devices --json-output "$J" >/dev/null 2>&1 || true
    DEV=$(python3 -I -c "
import json,sys
d=json.load(open(sys.argv[1]))
for x in d.get('result',{}).get('devices',[]):
    hw=x.get('hardwareProperties',{}); cp=x.get('connectionProperties',{})
    if hw.get('platform')=='iOS' and hw.get('deviceType')=='iPhone' and cp.get('tunnelState')!='unavailable':
        print(hw.get('udid') or x.get('identifier')); break" "$J" 2>/dev/null || true); rm -f "$J"
    [ -n "$DEV" ] || { echo "no iPhone connected (cable, unlocked, Developer Mode on)"; exit 1; }
    xcodebuild -project MC1.xcodeproj -scheme MC1 -configuration Release \
      -destination "id=$DEV" -derivedDataPath "$DD" -allowProvisioningUpdates build | tail -3
    APP="$DD/Build/Products/Release-iphoneos/MC1.app"
    xcrun devicectl device install app --device "$DEV" "$APP"
    echo "installed; a free account's install expires in 7 days: run this again before then"
    ;;
  *) sed -n '2,15p' "$0"; exit 1 ;;
esac
