#!/usr/bin/env bash
# Writes the signed Windows update manifest (latest.json) for one installer.
#   sign_windows_manifest.sh KEY.pem VALUNIVO-Setup-1.0.N.exe 1.0.N N OUT.json [rollback]
# KEY.pem = the Ed25519 release key (repository secret WINDOWS_UPDATE_SIGNING_KEY) — never committed, never printed.
# Output: {"format":1,"manifest":"<JSON text>","sig":"<base64 Ed25519 signature of exactly that text>"}
# The app verifies the signature with the public key compiled into it before it trusts anything in the manifest.
set -euo pipefail
KEY=$1; INST=$2; V=$3; B=$4; OUT=$5; RB=false
[ "${6:-}" = "rollback" ] && RB=true
NAME=$(basename "$INST")
[ "$NAME" = "VALUNIVO-Setup-$V.exe" ] || { echo "installer must be named VALUNIVO-Setup-$V.exe (got $NAME)" >&2; exit 1; }
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$B" =~ ^[0-9]+$ ]] || { echo "bad version / build" >&2; exit 1; }
SIZE=$(stat -c%s "$INST")
SHA=$(sha256sum "$INST" | cut -d' ' -f1)
ISSUED=$(date +%s)
M=$(printf '{"app":"VALUNIVO","platform":"windows-x64","channel":"stable","version":"%s","build":%s,"installer":"%s","size":%s,"sha256":"%s","issued":%s,"rollback":%s}' \
  "$V" "$B" "$NAME" "$SIZE" "$SHA" "$ISSUED" "$RB")
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
printf '%s' "$M" > "$T/m"
openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$T/m" -out "$T/s"
# never publish a signature that does not verify with the key's public half
openssl pkey -in "$KEY" -pubout -out "$T/pub.pem"
openssl pkeyutl -verify -pubin -inkey "$T/pub.pem" -rawin -in "$T/m" -sigfile "$T/s" >/dev/null
SIG=$(base64 -w0 < "$T/s")
ESC=$(printf '%s' "$M" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"format":1,"manifest":"%s","sig":"%s"}\n' "$ESC" "$SIG" > "$OUT"
echo "signed: $M" >&2
