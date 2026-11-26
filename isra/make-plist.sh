#!/bin/bash
# Info.plist for the isra build: upstream's MC1/Info.plist plus the keys the
# fork needs, written to isra/build/ (gitignored) so MC1/Info.plist stays as upstream has it.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p isra/build
P=isra/build/Info.plist
cp MC1/Info.plist "$P"
B=/usr/libexec/PlistBuddy
$B -c "Set :CFBundleDisplayName MC1 isra" "$P"
# background location: the radio asks for the phone's position for telemetry
if ! $B -c "Print :UIBackgroundModes" "$P" | grep -q location; then
  $B -c "Add :UIBackgroundModes: string location" "$P"
fi
$B -c "Delete :NSLocationAlwaysAndWhenInUseUsageDescription" "$P" 2>/dev/null || true
$B -c "Add :NSLocationAlwaysAndWhenInUseUsageDescription string 'MC1 isra sends your position to your own radio in the background, only for the telemetry your trusted contacts may request. It is never put in adverts.'" "$P"
echo "$P ok"
