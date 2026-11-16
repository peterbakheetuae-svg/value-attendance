#!/usr/bin/env bash
# Release rehearsal — NEVER touches the real server. Deploys a release-out folder into a throw-away copy of the server
# (fake WordPress + an existing stable release) with the real remote-deploy.sh, serves it on localhost, verifies it with
# the real verify_live.sh, then proves the safeguards:
#   1. the new release goes live and verifies; the previous stable release's files are kept
#   2. a tampered installer / APK is refused BEFORE anything changes (live files byte-identical)
#   3. a release whose served file is corrupted fails verification
#   4. WordPress files are never touched
#   rehearsal_test.sh OUT_DIR VERSION WINDOWS_PUBLIC_KEYS
set -euo pipefail
OUT=$(cd "$1" && pwd); V=$2; KEYS=$3
HERE=$(cd "$(dirname "$0")" && pwd); DEPLOY="$HERE/../../deploy/hostinger/remote-deploy.sh"
FAKE=$(mktemp -d); trap 'kill $SRV 2>/dev/null || true; rm -rf "$FAKE"' EXIT
ROOT="$FAKE/domains/jaurea.com/public_html"
mkdir -p "$ROOT/valunivo/android" "$ROOT/valunivo/windows" "$ROOT/value-attendance/android"
echo '<?php // wordpress' > "$ROOT/index.php"; echo 'wp' > "$ROOT/wp-config.php"; echo '# wp' > "$ROOT/.htaccess"
WP_BEFORE=$(cd "$ROOT" && sha256sum index.php wp-config.php .htaccess)
# the "existing stable release" already live
echo old-apk > "$ROOT/valunivo/android/value-attendance-1.0.1.apk"
echo '{"version":"1.0.1","build":1,"apk":"value-attendance-1.0.1.apk"}' > "$ROOT/valunivo/android/latest.json"
echo old-exe > "$ROOT/valunivo/windows/VALUNIVO-Setup-1.0.1.exe"
echo '{"format":1,"manifest":"{}","sig":""}' > "$ROOT/valunivo/windows/latest.json"

stage() {  # $1 = source release folder
  rm -rf "$FAKE/va-staging"; mkdir -p "$FAKE/va-staging/android" "$FAKE/va-staging/windows"
  cp "$1/web.zip" "$FAKE/va-staging/web.zip"
  cp "$1"/android/* "$FAKE/va-staging/android/"
  if [ -d "$1/windows" ]; then cp "$1"/windows/* "$FAKE/va-staging/windows/"; fi
}
live_hash() { (cd "$ROOT" && find valunivo value-attendance -type f -exec sha256sum {} + | sort -k2 | sha256sum | cut -d' ' -f1); }
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

PORT=$((20000 + RANDOM % 20000))
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$ROOT/.." >/dev/null 2>&1 &
SRV=$!; sleep 1
# the served tree is …/jaurea.com/public_html → URL base http://127.0.0.1:PORT/public_html
BASE="http://127.0.0.1:$PORT/public_html"

# 2a. tampered installer → refused before anything changes
if [ -d "$OUT/windows" ]; then
  T=$(mktemp -d); cp -r "$OUT"/. "$T"/; WIN=$(cut -d' ' -f1 "$T/windows/release.txt"); printf 'x' >> "$T/windows/$WIN"
  stage "$T"; H=$(live_hash)
  if HOME="$FAKE" bash "$DEPLOY" >"$FAKE/log" 2>&1; then fail "tampered installer was deployed"; fi
  [ "$(live_hash)" = "$H" ] || fail "files changed although the deploy was refused"
  pass "tampered Windows installer refused before anything changed ($(tail -1 "$FAKE/log"))"; rm -rf "$T"
fi
# 2b. tampered APK → refused before anything changes
T=$(mktemp -d); cp -r "$OUT"/. "$T"/; printf 'x' >> "$T"/android/*.apk
stage "$T"; H=$(live_hash)
if HOME="$FAKE" bash "$DEPLOY" >"$FAKE/log" 2>&1; then fail "tampered APK was deployed"; fi
[ "$(live_hash)" = "$H" ] || fail "files changed although the deploy was refused"
pass "tampered APK refused before anything changed ($(tail -1 "$FAKE/log"))"; rm -rf "$T"
# 2c. verification of the not-yet-deployed release must fail (the old one is live)
if bash "$HERE/verify_live.sh" "$BASE" "$V" "$KEYS" "$OUT" >/dev/null 2>&1; then fail "verification passed before deploying"; fi
pass "verification fails while the old release is live"

# 1. the real release
stage "$OUT"
HOME="$FAKE" bash "$DEPLOY" > "$FAKE/log" 2>&1 || { cat "$FAKE/log"; fail "deploy failed"; }
bash "$HERE/verify_live.sh" "$BASE" "$V" "$KEYS" "$OUT" || fail "verification of the deployed release failed"
pass "release $V deployed and verified"
for f in valunivo/android/value-attendance-1.0.1.apk valunivo/windows/VALUNIVO-Setup-1.0.1.exe; do
  [ -s "$ROOT/$f" ] || fail "previous stable file removed: $f"
done
if [ -d "$OUT/windows" ]; then grep -q '"manifest":"{}"' "$ROOT/valunivo/windows/latest.prev.json" || fail "previous Windows manifest not kept"; fi
pass "previous stable release files kept (APK, installer, latest.prev.json)"

# 3. a corrupted file on the server → verification fails
if [ -d "$OUT/windows" ]; then
  WIN=$(cut -d' ' -f1 "$OUT/windows/release.txt"); cp "$ROOT/valunivo/windows/$WIN" "$FAKE/keep.exe"
  printf 'x' >> "$ROOT/valunivo/windows/$WIN"
  if bash "$HERE/verify_live.sh" "$BASE" "$V" "$KEYS" "$OUT" >/dev/null 2>&1; then fail "corrupted live installer passed verification"; fi
  cp "$FAKE/keep.exe" "$ROOT/valunivo/windows/$WIN"; pass "corrupted live installer fails verification"
fi
APK="$ROOT/valunivo/android/value-attendance-$V.apk"; cp "$APK" "$FAKE/keep.apk"; printf 'x' >> "$APK"
if bash "$HERE/verify_live.sh" "$BASE" "$V" "$KEYS" "$OUT" >/dev/null 2>&1; then fail "corrupted live APK passed verification"; fi
cp "$FAKE/keep.apk" "$APK"; pass "corrupted live APK fails verification"
# a manifest signed by a key the app does not trust → verification fails
if [ -d "$OUT/windows" ]; then
  OTHER=$(openssl genpkey -algorithm ed25519 2>/dev/null | openssl pkey -pubout -outform DER | tail -c 32 | base64 -w0)
  if bash "$HERE/verify_live.sh" "$BASE" "$V" "$OTHER" "$OUT" >/dev/null 2>&1; then fail "manifest accepted with an untrusted key"; fi
  pass "live manifest refused with an untrusted key"
fi

# 4. WordPress untouched
[ "$(cd "$ROOT" && sha256sum index.php wp-config.php .htaccess)" = "$WP_BEFORE" ] || fail "WordPress files changed"
pass "WordPress files unchanged"
echo "REHEARSAL: ALL PASSED ($V)"
