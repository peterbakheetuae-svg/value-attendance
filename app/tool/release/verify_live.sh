#!/usr/bin/env bash
# Verifies a published release as users' apps will see it (used by the release job against https://jaurea.com and by the
# rehearsal against a local copy of the server). Exits non-zero on the first mismatch.
#   verify_live.sh BASE_URL VERSION WINDOWS_PUBLIC_KEYS OUT_DIR
#     BASE_URL     e.g. https://jaurea.com            (…/valunivo/, …/value-attendance/android/ are checked under it)
#     VERSION      1.0.N
#     WINDOWS_PUBLIC_KEYS  base64 raw Ed25519 key(s) the Windows app trusts, comma-separated
#     OUT_DIR      the release-out folder (expected android/latest.json; windows/ optional)
#   … OUT_DIR --windows-only   only the Windows update; OUT_DIR holds latest.json + the installer
set -euo pipefail
BASE=${1%/}; V=$2; KEYS=$3; OUT=$4; ONLY=${5:-}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fetch() { curl -fsS --max-time 300 -o "$2" "$1?t=$(date +%s%N)"; }

if [ "$ONLY" = "--windows-only" ]; then mkdir -p "$W/o/windows"; cp "$OUT"/latest.json "$W/o/windows/"; OUT="$W/o"; fi
if [ "$ONLY" != "--windows-only" ]; then
# Web: the live build is this release
fetch "$BASE/valunivo/version.json" "$W/version.json"
grep -q "\"version\":\"$V\"" "$W/version.json" || { echo "web version.json is not $V: $(cat "$W/version.json")" >&2; exit 1; }
echo "web: $V"

# Android: latest.json (new and old address) names this version, and the APK served is the exact file
WANT=$(sed -n 's/.*"sha256" *: *"\([0-9a-f]*\)".*/\1/p' "$OUT/android/latest.json")
for d in valunivo value-attendance; do
  fetch "$BASE/$d/android/latest.json" "$W/a.json"
  grep -q "\"version\":\"$V\"" "$W/a.json" || { echo "$d/android/latest.json is not $V" >&2; exit 1; }
  fetch "$BASE/$d/android/value-attendance-$V.apk" "$W/a.apk"
  [ "$(sha256sum "$W/a.apk" | cut -d' ' -f1)" = "$WANT" ] || { echo "$d: live APK differs from the release" >&2; exit 1; }
done
echo "android: $V"
fi

# Windows: the live manifest verifies with a key the app trusts, and the live installer is exactly the signed one
if [ -s "$OUT/windows/latest.json" ]; then
  fetch "$BASE/valunivo/windows/latest.json" "$W/w.json"
  python3 - "$V" "$KEYS" "$W" <<'PY'
import base64, json, subprocess, sys
v, keys, w = sys.argv[1], [k for k in sys.argv[2].split(',') if k.strip()], sys.argv[3]
env = json.load(open(f'{w}/w.json'))
text, sig = env['manifest'].encode(), base64.b64decode(env['sig'])
open(f'{w}/m', 'wb').write(text); open(f'{w}/s', 'wb').write(sig)
ok = False
for k in keys:
    # raw Ed25519 public key → SubjectPublicKeyInfo DER for openssl
    open(f'{w}/pub.der', 'wb').write(bytes.fromhex('302a300506032b6570032100') + base64.b64decode(k))
    r = subprocess.run(['openssl', 'pkeyutl', '-verify', '-pubin', '-keyform', 'DER', '-inkey', f'{w}/pub.der',
                        '-rawin', '-in', f'{w}/m', '-sigfile', f'{w}/s'], capture_output=True)
    ok = ok or r.returncode == 0
if not ok:
    sys.exit('live Windows manifest does not verify with the trusted key(s)')
m = json.loads(text)
if m.get('version') != v or m.get('app') != 'VALUNIVO' or m.get('platform') != 'windows-x64':
    sys.exit(f'live Windows manifest is not {v}: {m}')
open(f'{w}/win.txt', 'w').write(f"{m['installer']} {m['sha256']} {m['size']}\n")
PY
  read -r NAME SHA SIZE < "$W/win.txt"
  fetch "$BASE/valunivo/windows/$NAME" "$W/w.exe"
  [ "$(sha256sum "$W/w.exe" | cut -d' ' -f1)" = "$SHA" ] && [ "$(stat -c%s "$W/w.exe")" = "$SIZE" ] \
    || { echo "live Windows installer does not match the signed manifest" >&2; exit 1; }
  echo "windows: $V (signature + installer verified)"
fi
echo "LIVE OK: $V"
