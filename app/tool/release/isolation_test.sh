#!/usr/bin/env bash
# Deployment isolation test — runs the REAL server scripts against a throw-away copy of the server (never the real one).
#   isolation_test.sh WEB_ZIP
# Proves:
#   W1  a web + Android deploy (remote-deploy.sh) leaves valunivo/windows/ byte-identical (contents + file list)
#   W2  what happens if a web build ever CONTAINED a windows/ folder (reported, not assumed)
#   X1  a Windows deploy (remote-deploy-windows.sh) changes nothing outside valunivo/windows/ (web, Android, WordPress)
#   X2  the Windows deploy refuses tampered / unexpected / path-traversal input before changing anything
#   X3  web deploy → Windows deploy → web deploy: both stay intact
set -uo pipefail
WEBZIP=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
HERE=$(cd "$(dirname "$0")" && pwd)
WEBDEPLOY="$HERE/../../deploy/hostinger/remote-deploy.sh"
WINDEPLOY="$HERE/../../deploy/hostinger/remote-deploy-windows.sh"
FAKE=$(mktemp -d); trap 'rm -rf "$FAKE"' EXIT
export HOME="$FAKE"
ROOT="$FAKE/domains/jaurea.com/public_html"; APP="$ROOT/valunivo"
FAILS=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILS=$((FAILS+1)); }
tree_hash() { (cd "$1" 2>/dev/null && find . -type f -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1); }
outside_windows() { (cd "$ROOT" && find . -path ./valunivo/windows -prune -o -type f -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1); }

# --- the "live" server: WordPress + web app + Android update + old address + Windows update
mkdir -p "$APP/android" "$APP/windows" "$ROOT/value-attendance/android"
echo '<?php // WordPress' > "$ROOT/index.php"; echo 'wp-config' > "$ROOT/wp-config.php"; echo '# WordPress' > "$ROOT/.htaccess"
(cd "$APP" && unzip -q "$WEBZIP")
head -c 3000 /dev/urandom > "$APP/android/value-attendance-1.0.118.apk"
echo '{"version":"1.0.118","build":118,"apk":"value-attendance-1.0.118.apk"}' > "$APP/android/latest.json"
cp "$APP/android/"* "$ROOT/value-attendance/android/"
head -c 5000 /dev/urandom > "$APP/windows/VALUNIVO-Setup-1.0.5.exe"; cp "$APP/windows/VALUNIVO-Setup-1.0.5.exe" "$APP/windows/VALUNIVO-Setup.exe"
echo '{"format":1,"manifest":"{\"version\":\"1.0.5\"}","sig":"x"}' > "$APP/windows/latest.json"
echo 'RewriteEngine Off' > "$APP/windows/.htaccess"
WP0=$(cd "$ROOT" && sha256sum index.php wp-config.php .htaccess)

stage_web() {  # $1 web.zip, $2 = with android update (1/0)
  rm -rf "$FAKE/va-staging"; mkdir -p "$FAKE/va-staging/android"; cp "$1" "$FAKE/va-staging/web.zip"
  if [ "${2:-0}" = 1 ]; then
    head -c 4000 /dev/urandom > "$FAKE/va-staging/android/value-attendance-1.0.130.apk"
    echo '{"version":"1.0.130","build":130,"apk":"value-attendance-1.0.130.apk"}' > "$FAKE/va-staging/android/latest.json"
  fi
}
stage_win() {  # $1 version
  rm -rf "$FAKE/va-win-staging"; mkdir -p "$FAKE/va-win-staging"; local n="VALUNIVO-Setup-$1.exe"
  head -c 6000 /dev/urandom > "$FAKE/va-win-staging/$n"
  local sha; sha=$(sha256sum "$FAKE/va-win-staging/$n" | cut -d' ' -f1)
  echo "$n $sha" > "$FAKE/va-win-staging/release.txt"
  echo "{\"format\":1,\"manifest\":\"{\\\"version\\\":\\\"$1\\\",\\\"sha256\\\":\\\"$sha\\\"}\",\"sig\":\"x\"}" > "$FAKE/va-win-staging/latest.json"
}

# W1 — web + Android deploy leaves valunivo/windows/ untouched
WIN0=$(tree_hash "$APP/windows"); LIST0=$(cd "$APP/windows" && find . | sort)
stage_web "$WEBZIP" 1
if bash "$WEBDEPLOY" > "$FAKE/log" 2>&1; then
  grep -q '"version":"1.0.130"' "$APP/android/latest.json" || fail "W1 web+android deploy did not publish android (test setup)"
  [ "$(tree_hash "$APP/windows")" = "$WIN0" ] && [ "$(cd "$APP/windows" && find . | sort)" = "$LIST0" ] \
    && pass "W1 web + Android deploy: valunivo/windows/ byte-identical (same files, same contents)" \
    || fail "W1 web + Android deploy changed valunivo/windows/"
else fail "W1 web deploy failed: $(tail -2 "$FAKE/log")"; fi
if unzip -l "$WEBZIP" | awk '{print $4}' | grep -qE '^windows(/|$)'; then fail "W1 the real web build contains a windows/ folder"; else pass "W1 the real web build contains no windows/ folder"; fi

# W2 — a web.zip that (wrongly) contains windows/ files
T=$(mktemp -d); (cd "$T" && unzip -q "$WEBZIP" && mkdir -p windows && echo '{"evil":1}' > windows/latest.json && zip -qr "$FAKE/bad-web.zip" .); rm -rf "$T"
WIN0=$(tree_hash "$APP/windows"); stage_web "$FAKE/bad-web.zip" 0
if bash "$WEBDEPLOY" > "$FAKE/log" 2>&1; then
  if [ "$(tree_hash "$APP/windows")" = "$WIN0" ]; then pass "W2 web.zip containing windows/: valunivo/windows/ untouched"
  else echo "INFO  W2 web.zip containing windows/ — remote-deploy.sh (main) DOES overwrite valunivo/windows/latest.json (guard needed; see report)"
       cp "$FAKE/keep-latest.json" "$APP/windows/latest.json" 2>/dev/null || echo '{"format":1,"manifest":"{\"version\":\"1.0.5\"}","sig":"x"}' > "$APP/windows/latest.json"; fi
else pass "W2 web.zip containing windows/ refused: $(tail -1 "$FAKE/log")"; fi

# X1 — Windows deploy touches nothing outside valunivo/windows/
OUT0=$(outside_windows); WEBV=$(cat "$APP/version.json")
stage_win 1.0.6
if bash "$WINDEPLOY" > "$FAKE/log" 2>&1; then
  [ "$(outside_windows)" = "$OUT0" ] && pass "X1 Windows deploy: web, Android, old address and WordPress byte-identical" || fail "X1 Windows deploy changed files outside valunivo/windows/"
  grep -q '1.0.6' "$APP/windows/latest.json" && [ -s "$APP/windows/VALUNIVO-Setup-1.0.6.exe" ] && [ -s "$APP/windows/VALUNIVO-Setup-1.0.5.exe" ] \
    && pass "X1 Windows 1.0.6 live; previous installer 1.0.5 kept; latest.prev.json $( [ -s "$APP/windows/latest.prev.json" ] && echo kept)" || fail "X1 Windows update not published correctly"
  [ "$(cat "$APP/version.json")" = "$WEBV" ] || fail "X1 web version changed"
else fail "X1 Windows deploy failed: $(tail -2 "$FAKE/log")"; fi

# X2 — refused before anything changes
refused() {  # $1 label, then a function that damages the staging
  local before; before=$(tree_hash "$ROOT"); stage_win 1.0.7; "$2"
  if bash "$WINDEPLOY" > "$FAKE/log" 2>&1; then fail "X2 $1 was deployed"
  elif [ "$(tree_hash "$ROOT")" = "$before" ]; then pass "X2 $1 refused, nothing changed ($(tail -1 "$FAKE/log"))"
  else fail "X2 $1 refused but files changed"; fi
}
tamper() { printf 'x' >> "$FAKE/va-win-staging/VALUNIVO-Setup-1.0.7.exe"; }
extra() { echo '<html>evil</html>' > "$FAKE/va-win-staging/index.html"; }
travel() { sed -i 's#^VALUNIVO-Setup-1.0.7.exe#../../index.php#' "$FAKE/va-win-staging/release.txt"; }
othermanifest() { echo '{"format":1,"manifest":"{}","sig":"x"}' > "$FAKE/va-win-staging/latest.json"; }
refused "tampered installer" tamper
refused "an extra (non-Windows) file in the staging" extra
refused "a path-traversal installer name (../../index.php)" travel
refused "a manifest that does not name the installer" othermanifest

# X3 — web deploy after a Windows deploy, then Windows again
WIN1=$(tree_hash "$APP/windows"); stage_web "$WEBZIP" 0
bash "$WEBDEPLOY" > "$FAKE/log" 2>&1 && [ "$(tree_hash "$APP/windows")" = "$WIN1" ] && pass "X3 web deploy after a Windows deploy: Windows update intact" || fail "X3 web deploy disturbed the Windows update"
OUT1=$(outside_windows); stage_win 1.0.8
bash "$WINDEPLOY" > "$FAKE/log" 2>&1 && [ "$(outside_windows)" = "$OUT1" ] && pass "X3 second Windows deploy: web + Android intact" || fail "X3 second Windows deploy disturbed web / Android"
[ "$(cd "$ROOT" && sha256sum index.php wp-config.php .htaccess)" = "$WP0" ] && pass "WordPress files unchanged throughout" || fail "WordPress files changed"

echo "isolation: $FAILS failure(s)"; exit $FAILS
