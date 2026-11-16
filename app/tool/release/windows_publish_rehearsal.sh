#!/usr/bin/env bash
# Rehearses the Windows publish (never the real server): sign → remote-deploy-windows.sh into a throw-away server
# copy → serve on localhost → verify_live.sh --windows-only; then a corrupted live installer and an untrusted key must fail.
#   windows_publish_rehearsal.sh INSTALLER.exe VERSION      (uses a throw-away key; never the release key)
set -euo pipefail
INST=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); V=$2; N=${V##*.}
HERE=$(cd "$(dirname "$0")" && pwd)
FAKE=$(mktemp -d); trap 'kill ${SRV:-0} 2>/dev/null || true; rm -rf "$FAKE"' EXIT
ROOT="$FAKE/domains/jaurea.com/public_html"; mkdir -p "$ROOT/valunivo/android"
echo wp > "$ROOT/index.php"; echo web > "$ROOT/valunivo/index.html"; echo '{"version":"1.0.118"}' > "$ROOT/valunivo/android/latest.json"
openssl genpkey -algorithm ed25519 -out "$FAKE/k.pem"; PUB=$(bash "$HERE/public_key.sh" "$FAKE/k.pem")
mkdir -p "$FAKE/stage"; cp "$INST" "$FAKE/stage/VALUNIVO-Setup-$V.exe"
bash "$HERE/sign_windows_manifest.sh" "$FAKE/k.pem" "$FAKE/stage/VALUNIVO-Setup-$V.exe" "$V" "$N" "$FAKE/stage/latest.json" 2>/dev/null; rm -f "$FAKE/k.pem"
echo "VALUNIVO-Setup-$V.exe $(sha256sum "$FAKE/stage/VALUNIVO-Setup-$V.exe" | cut -d' ' -f1)" > "$FAKE/stage/release.txt"
mkdir -p "$FAKE/va-win-staging"; cp "$FAKE/stage"/* "$FAKE/va-win-staging/"
HOME="$FAKE" bash "$HERE/../../deploy/hostinger/remote-deploy-windows.sh"
PORT=$((20000 + RANDOM % 20000)); python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$ROOT/.." >/dev/null 2>&1 & SRV=$!; sleep 1
BASE="http://127.0.0.1:$PORT/public_html"
bash "$HERE/verify_live.sh" "$BASE" "$V" "$PUB" "$FAKE/stage" --windows-only && echo "PASS  published Windows update verifies (signature + installer)"
OTHER=$(openssl genpkey -algorithm ed25519 2>/dev/null | openssl pkey -pubout -outform DER | tail -c 32 | base64 -w0)
if bash "$HERE/verify_live.sh" "$BASE" "$V" "$OTHER" "$FAKE/stage" --windows-only >/dev/null 2>&1; then echo "FAIL  untrusted key accepted"; exit 1; else echo "PASS  untrusted key refused"; fi
printf 'x' >> "$ROOT/valunivo/windows/VALUNIVO-Setup-$V.exe"
if bash "$HERE/verify_live.sh" "$BASE" "$V" "$PUB" "$FAKE/stage" --windows-only >/dev/null 2>&1; then echo "FAIL  corrupted installer accepted"; exit 1; else echo "PASS  corrupted live installer refused"; fi
echo "WINDOWS PUBLISH REHEARSAL: ALL PASSED"
