#!/bin/bash
# Windows update ONLY. Runs ON the Hostinger server (sent over SSH by windows.yml → publish).
# Writes inside public_html/valunivo/windows/ and nowhere else: the web app, the Android update (valunivo/android/,
# value-attendance/) and WordPress are fingerprinted before and after — the deploy fails if anything outside
# valunivo/windows/ changed. Independent from the web / Android deploy (remote-deploy.sh), which it never runs.
#
# Expects in ~/va-win-staging/: VALUNIVO-Setup-<v>.exe, latest.json (signed manifest), release.txt ("<installer> <sha256>").
set -euo pipefail

ROOT="$HOME/domains/jaurea.com/public_html"
APP="$ROOT/valunivo"
WIN="$APP/windows"
STAGE="$HOME/va-win-staging"

test -d "$ROOT" || { echo "site folder missing: $ROOT"; exit 1; }
test -d "$APP" || { echo "web app folder missing: $APP (deploy the web first)"; exit 1; }

# fingerprint of everything this deploy must NOT touch: the whole public_html except valunivo/windows/
outside() { (cd "$ROOT" && find . -path ./valunivo/windows -prune -o -type f -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1); }
BEFORE=$(outside)

# --- check the staged update completely before anything goes live
read -r NAME SHA < "$STAGE/release.txt" || true
[[ "${NAME:-}" =~ ^VALUNIVO-Setup-[0-9]+\.[0-9]+\.[0-9]+\.exe$ ]] || { echo "bad installer name"; exit 1; }
test -s "$STAGE/$NAME" || { echo "installer missing"; exit 1; }
[ "$(sha256sum "$STAGE/$NAME" | cut -d' ' -f1)" = "$SHA" ] || { echo "windows installer hash mismatch"; exit 1; }
test -s "$STAGE/latest.json" || { echo "latest.json missing"; exit 1; }
grep -q "\"format\":1" "$STAGE/latest.json" && grep -q "$SHA" "$STAGE/latest.json" || { echo "manifest does not name this installer"; exit 1; }
for f in "$STAGE"/*; do
  case "$(basename "$f")" in "$NAME"|latest.json|release.txt) ;; *) echo "unexpected file staged: $(basename "$f")"; exit 1;; esac
done
echo "windows update checked: $NAME"

# --- publish: installer first, signed latest.json last; earlier installers stay (a signed rollback can point at one)
mkdir -p "$WIN"
cp "$STAGE/$NAME" "$WIN/$NAME.tmp" && mv "$WIN/$NAME.tmp" "$WIN/$NAME"
cp "$STAGE/$NAME" "$WIN/VALUNIVO-Setup.exe.tmp" && mv "$WIN/VALUNIVO-Setup.exe.tmp" "$WIN/VALUNIVO-Setup.exe"   # fixed link for a first install
cat > "$WIN/.htaccess" <<'HT'
# VALUNIVO Windows updates — plain files only (no web-app rewrites here: a missing file is a real 404)
Options -Indexes
<IfModule mod_rewrite.c>
  RewriteEngine Off
</IfModule>
<IfModule mod_mime.c>
  AddType application/json .json
  AddType application/octet-stream .exe
</IfModule>
<IfModule mod_headers.c>
  <FilesMatch "\.json$">
    Header set Cache-Control "no-cache"
  </FilesMatch>
</IfModule>
<FilesMatch "^(\.|release\.txt)">
  Require all denied
</FilesMatch>
HT
if [ -s "$WIN/latest.json" ]; then cp "$WIN/latest.json" "$WIN/latest.prev.json"; fi
cp "$STAGE/latest.json" "$WIN/latest.json.tmp" && mv "$WIN/latest.json.tmp" "$WIN/latest.json"
find "$WIN" -type d -exec chmod 755 {} +
find "$WIN" -type f -exec chmod 644 {} +
rm -rf "$STAGE"

AFTER=$(outside)
[ "$BEFORE" = "$AFTER" ] || { echo "files outside valunivo/windows/ changed during the Windows deploy!"; exit 1; }
echo "windows update live: $NAME (nothing outside valunivo/windows/ changed)"
