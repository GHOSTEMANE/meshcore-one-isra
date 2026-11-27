#!/bin/bash
# isra tests (macOS, Xcode). Same steps on this Mac and in the "isra - testar e compilar" Action.
#
#   isra/ci-test.sh            everything below
#   isra/ci-test.sh packages   only the Swift packages (no simulator)
#   isra/ci-test.sh app        only the app: simulator build + MC1Tests isra suites
#
# 1. MeshCore package: the whole suite (upstream's protocol tests plus the isra ones).
# 2. MC1Services package: the isra suites (upstream's whole suite can stall; it runs in
#    upstream's own CI).
# 3. The app, generated from isra.yml, built for the simulator, and the MC1Tests isra
#    suites run one at a time on an iPhone simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
DD=isra/build/dd
WHAT="${1:-all}"

packages() {
  echo "::group::MeshCore (todos os testes)"
  swift test --package-path MeshCore --no-parallel
  echo "::endgroup::"
  echo "::group::MC1Services (testes isra)"
  swift test --package-path MC1Services --no-parallel --filter Isra
  echo "::endgroup::"
}

app() {
  echo "::group::Gerar o projeto"
  isra/build.sh generate
  echo "::endgroup::"
  SIM=$(xcrun simctl list devices available -j | python3 -I -c "
import json,sys
d=json.load(sys.stdin)['devices']
best=None
for rt,devs in d.items():
    if 'iOS' not in rt: continue
    for x in devs:
        if x['name'].startswith('iPhone'):
            v=tuple(int(p) for p in rt.rsplit('iOS-',1)[-1].split('-') if p.isdigit())
            if best is None or v>best[0]: best=(v,x['udid'],x['name'])
print(best[1] if best else '')")
  [ -n "$SIM" ] || { echo "sem simulador de iPhone"; exit 1; }
  echo "simulador: $SIM"
  SUITES=$(grep -hoE '^struct (Isra[A-Za-z]+Tests)' MC1Tests/Isra/*.swift | awk '{print $2}')
  [ -n "$SUITES" ] || { echo "sem suites isra em MC1Tests/Isra"; exit 1; }
  echo "::group::Compilar a app e os testes"
  xcodebuild build-for-testing -project MC1.xcodeproj -scheme MC1 -configuration Debug \
    -destination "id=$SIM" -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO -quiet
  echo "::endgroup::"
  LOG=$(mktemp)
  for s in $SUITES; do
    xcodebuild test-without-building -project MC1.xcodeproj -scheme MC1 -configuration Debug \
      -destination "id=$SIM" -derivedDataPath "$DD" -only-testing:"MC1Tests/$s" > "$LOG" 2>&1 \
      || { cat "$LOG"; echo "MC1Tests/$s falhou"; exit 1; }
    # a suite name that matches nothing runs zero tests and "succeeds": refuse that
    grep -E 'Test run with [1-9][0-9]* tests? .*passed' "$LOG" | sed "s|^|MC1Tests/$s: |" \
      || { cat "$LOG"; echo "MC1Tests/$s: nenhum teste correu"; exit 1; }
  done
  rm -f "$LOG"
}

case "$WHAT" in
  all) packages; app ;;
  packages) packages ;;
  app) app ;;
  *) sed -n '2,13p' "$0"; exit 1 ;;
esac
echo "isra: testes OK"
