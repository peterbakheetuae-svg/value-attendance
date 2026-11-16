#!/bin/bash
# Android updates are served from jaurea.com/valunivo/android/ (and the old /value-attendance/android/ for phones on older versions) (latest.json + the APK); signed with the key in the repository secrets.
# Runs ON the Hostinger server (sent over SSH by the build). Puts the new web build — and, when there is one,
# the new Android update — into public_html/valunivo/ ONLY (+ the old public_html/value-attendance/: a redirect and its android/). WordPress (the rest of public_html) is never
# touched: its key files are fingerprinted before and after, and the deploy fails if anything there changed.
#
# Expects in ~/va-staging/: web.zip, and optionally android/ (value-attendance-<v>.apk + latest.json).
set -euo pipefail

ROOT="$HOME/domains/jaurea.com/public_html"
APP="$ROOT/valunivo"
OLD="$ROOT/value-attendance"   # the old address: sends people to the new one, still hands Android updates to older phones
STAGE="$HOME/va-staging"

fp() { (cd "$ROOT" && sha256sum .htaccess index.php wp-config.php 2>/dev/null) || true; }
BEFORE=$(fp)

test -d "$ROOT" || { echo "site folder missing: $ROOT"; exit 1; }
mkdir -p "$APP"
test -s "$STAGE/web.zip" || { echo "web.zip missing"; exit 1; }
rm -rf "$STAGE/web" && mkdir -p "$STAGE/web"
unzip -q "$STAGE/web.zip" -d "$STAGE/web"

# the build must be complete, point at /valunivo/, and hold nothing secret
for f in index.html flutter_bootstrap.js main.dart.js .htaccess assets/AssetManifest.bin.json; do
  test -s "$STAGE/web/$f" || { echo "build incomplete: $f"; exit 1; }
done
grep -q '<base href="/valunivo/">' "$STAGE/web/index.html" || { echo "wrong base href"; exit 1; }
if find "$STAGE/web" -name '*.env' -o -name '*.p12' -o -name '*.jks' -o -name 'key.properties' | grep -q .; then
  echo "secret file in build"; exit 1
fi

# everything except the two entry files first (the running app keeps working), then the entry files
(cd "$STAGE/web" && tar cf - --exclude=./index.html --exclude=./flutter_bootstrap.js .) | (cd "$APP" && tar xf -)
cp "$STAGE/web/flutter_bootstrap.js" "$STAGE/web/index.html" "$APP/"

# Android update: the APK first, latest.json last (phones only see a version once its file is fully there)
if [ -s "$STAGE/android/latest.json" ]; then
  mkdir -p "$APP/android"
  APK=$(sed -n 's/.*"apk" *: *"\([^"]*\)".*/\1/p' "$STAGE/android/latest.json")
  test -n "$APK" && test -s "$STAGE/android/$APK" || { echo "android update incomplete"; exit 1; }
  cp "$STAGE/android/$APK" "$APP/android/$APK"
  cp "$STAGE/android/$APK" "$APP/android/value-attendance.apk"   # fixed link for a first / manual install
  cp "$STAGE/android/latest.json" "$APP/android/latest.json"
  # phones on a version from before the move still ask the old address
  mkdir -p "$OLD/android"
  cp "$STAGE/android/$APK" "$OLD/android/$APK"
  cp "$STAGE/android/$APK" "$OLD/android/value-attendance.apk"
  cp "$STAGE/android/latest.json" "$OLD/android/latest.json"
  echo "android update: $APK"
fi

# the old address → the new one (everything except android/, which older phones still read)
mkdir -p "$OLD"
cat > "$OLD/.htaccess" <<'HT'
# Old address of Value Nivo — the app moved to https://jaurea.com/valunivo/
Options -Indexes
<IfModule mod_rewrite.c>
  RewriteEngine On
  RewriteBase /value-attendance/
  RewriteRule ^android/ - [L]
  RewriteRule ^(.*)$ /valunivo/$1 [R=302,L]
</IfModule>
<IfModule mod_mime.c>
  AddType application/json .json
  AddType application/vnd.android.package-archive .apk
</IfModule>
<IfModule mod_headers.c>
  <FilesMatch "\.(json|apk)$">
    Header set Cache-Control "no-cache"
  </FilesMatch>
</IfModule>
<FilesMatch "^\.">
  Require all denied
</FilesMatch>
HT
find "$OLD" -type d -exec chmod 755 {} +
find "$OLD" -type f -exec chmod 644 {} +
find "$APP" -type d -exec chmod 755 {} +
find "$APP" -type f -exec chmod 644 {} +
rm -rf "$STAGE"

AFTER=$(fp)
[ "$BEFORE" = "$AFTER" ] || { echo "WordPress files changed during the deploy!"; exit 1; }
echo "deployed: $(cat "$APP/version.json" 2>/dev/null)"
