#!/bin/bash
# Android-only update (or rollback) on the Hostinger server — the web build is NOT touched.
# Sent over SSH by app.yml (job android-update). Places a new APK + latest.json into
#   public_html/valunivo/android/ and public_html/value-attendance/android/ (older phones still ask the old address)
# after a verified backup of what is served now. WordPress (the rest of public_html) is fingerprinted before / after.
#
#   update:   bash -s -- update            (expects ~/va-staging-android/latest.json + the APK it names)
#   rollback: bash -s -- rollback <dir>    (<dir> = a folder name under ~/va-backups/, e.g. android-20261123T090000Z)
#
# A rollback puts the backed-up latest.json and value-attendance.apk back; versioned APK files are never deleted.
# Phones that already installed the newer build keep it (Android never offers a lower build) — a rollback stops the
# offer to the others.
set -euo pipefail

ROOT="$HOME/domains/jaurea.com/public_html"
DIRS=(valunivo value-attendance)
STAGE="$HOME/va-staging-android"
BACKUPS="$HOME/va-backups"
MODE="${1:-}"

fp() { (cd "$ROOT" && sha256sum .htaccess index.php wp-config.php 2>/dev/null) || true; }
json() { sed -n "s/.*\"$2\" *: *\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$1"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

test -d "$ROOT" || { echo "site folder missing: $ROOT"; exit 1; }
BEFORE=$(fp)

if [ "$MODE" = "update" ]; then
  test -s "$STAGE/latest.json" || { echo "staged latest.json missing"; exit 1; }
  APK=$(json "$STAGE/latest.json" apk); WANT=$(json "$STAGE/latest.json" sha256); NEWB=$(json "$STAGE/latest.json" build)
  [[ "$APK" =~ ^value-attendance-1\.0\.[0-9]+\.apk$ ]] || { echo "bad apk name: $APK"; exit 1; }
  test -s "$STAGE/$APK" || { echo "staged APK missing"; exit 1; }
  [ "$(sha "$STAGE/$APK")" = "$WANT" ] || { echo "staged APK sha256 differs from latest.json"; exit 1; }

  # 1. backup of what is served now (both addresses), verified before anything is replaced
  BK="$BACKUPS/android-$(date -u +%Y%m%dT%H%M%SZ)"
  for d in "${DIRS[@]}"; do
    A="$ROOT/$d/android"; mkdir -p "$BK/$d"
    test -s "$A/latest.json" || { echo "$d: nothing published to back up"; exit 1; }
    OLDAPK=$(json "$A/latest.json" apk); OLDSHA=$(json "$A/latest.json" sha256); OLDB=$(json "$A/latest.json" build)
    [ "$NEWB" -gt "$OLDB" ] || { echo "$d: new build $NEWB is not newer than the published $OLDB"; exit 1; }
    cp -p "$A/latest.json" "$BK/$d/latest.json"
    cp -p "$A/$OLDAPK" "$BK/$d/$OLDAPK"
    cp -p "$A/value-attendance.apk" "$BK/$d/value-attendance.apk"
    [ "$(sha "$BK/$d/$OLDAPK")" = "$OLDSHA" ] || { echo "$d: backup of $OLDAPK does not match its latest.json"; exit 1; }
    echo "backup $d: $OLDAPK build $OLDB sha256 $OLDSHA (fixed link sha256 $(sha "$BK/$d/value-attendance.apk"))"
  done
  echo "backup folder: $(basename "$BK")"

  # 2. the APK first, the fixed link, latest.json last (phones only see the version once its file is fully there)
  for d in "${DIRS[@]}"; do
    A="$ROOT/$d/android"
    cp "$STAGE/$APK" "$A/$APK.tmp" && mv -f "$A/$APK.tmp" "$A/$APK"
    cp "$STAGE/$APK" "$A/value-attendance.apk.tmp" && mv -f "$A/value-attendance.apk.tmp" "$A/value-attendance.apk"
    cp "$STAGE/latest.json" "$A/latest.json.tmp" && mv -f "$A/latest.json.tmp" "$A/latest.json"
    chmod 644 "$A/$APK" "$A/value-attendance.apk" "$A/latest.json"
    [ "$(sha "$A/$APK")" = "$WANT" ] && [ "$(sha "$A/value-attendance.apk")" = "$WANT" ] || { echo "$d: installed file differs"; exit 1; }
    echo "android update $d: $APK build $NEWB"
  done
  rm -rf "$STAGE"

elif [ "$MODE" = "rollback" ]; then
  NAME="${2:-}"
  [[ "$NAME" =~ ^android-[0-9]{8}T[0-9]{6}Z$ ]] || { echo "bad backup name: $NAME"; exit 1; }
  BK="$BACKUPS/$NAME"; test -d "$BK" || { echo "no backup $NAME"; exit 1; }
  for d in "${DIRS[@]}"; do
    A="$ROOT/$d/android"; S="$BK/$d"
    OLDAPK=$(json "$S/latest.json" apk); OLDSHA=$(json "$S/latest.json" sha256)
    [ "$(sha "$S/$OLDAPK")" = "$OLDSHA" ] || { echo "$d: backup damaged"; exit 1; }
    cp -p "$S/$OLDAPK" "$A/$OLDAPK"
    cp "$S/value-attendance.apk" "$A/value-attendance.apk.tmp" && mv -f "$A/value-attendance.apk.tmp" "$A/value-attendance.apk"
    cp "$S/latest.json" "$A/latest.json.tmp" && mv -f "$A/latest.json.tmp" "$A/latest.json"
    chmod 644 "$A/$OLDAPK" "$A/value-attendance.apk" "$A/latest.json"
    echo "rollback $d: latest.json → $OLDAPK"
  done
else
  echo "usage: update | rollback <backup-folder>"; exit 2
fi

AFTER=$(fp)
[ "$BEFORE" = "$AFTER" ] || { echo "WordPress files changed during the update!"; exit 1; }
echo "done ($MODE)"
