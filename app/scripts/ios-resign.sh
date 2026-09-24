#!/bin/bash
# Rebuilds the iOS app with a fresh free-Apple-ID provisioning profile (valid 7 days)
# and installs it on the iPhone over Wi-Fi. Meant to be run by launchd, see
# ios-resign-install.sh and the README section "iOS ohne Bezahl-Account".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="$SCRIPT_DIR/ios-resign.env"
STATE_DIR="$HOME/Library/Application Support/faden"
STAMP="$STATE_DIR/last-ios-resign"

log() { echo "$(date '+%F %T') $1"; }

notify() {
  /usr/bin/osascript -e "display notification \"$1\" with title \"Faden\"" >/dev/null 2>&1 || true
}

fail() {
  log "FEHLER: $1" >&2
  notify "App-Erneuerung fehlgeschlagen: $1"
  exit 1
}

[ -f "$CONFIG" ] || fail "Konfiguration fehlt: $CONFIG (Vorlage: ios-resign.env.example)"
# shellcheck source=/dev/null
. "$CONFIG"
[ -n "${FADEN_DEVICE:-}" ] || fail "FADEN_DEVICE ist in $CONFIG nicht gesetzt"
BUNDLE_ID="${BUNDLE_ID:-de.faden.faden}"
MIN_DAYS="${MIN_DAYS:-3}"

# launchd starts jobs with a minimal PATH and no locale; CocoaPods refuses to run without UTF-8.
export PATH="${EXTRA_PATH:+$EXTRA_PATH:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LANG="${LANG:-en_US.UTF-8}"
command -v flutter >/dev/null || fail "flutter nicht gefunden, EXTRA_PATH in $CONFIG setzen"

if [ -f "$STAMP" ] && [ "${1:-}" != "--force" ]; then
  age_days=$(( ($(date +%s) - $(cat "$STAMP")) / 86400 ))
  if [ "$age_days" -lt "$MIN_DAYS" ]; then
    log "Letzte Erneuerung vor $age_days Tag(en), nichts zu tun (MIN_DAYS=$MIN_DAYS)."
    exit 0
  fi
fi

# After waking from sleep Wi-Fi may still be reconnecting; Apple's servers are needed for the profile.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sfI --max-time 5 https://developer.apple.com >/dev/null && break
  sleep 30
done
curl -sfI --max-time 5 https://developer.apple.com >/dev/null || fail "keine Internetverbindung"

log "Start"

# Xcode keeps reusing a still-valid profile, so rebuilding alone would not extend the 7 days.
# Remove only this app's team profiles; -allowProvisioningUpdates (passed by flutter) fetches a new one.
bundle_suffix=".$BUNDLE_ID</string>"
for dir in "$HOME/Library/MobileDevice/Provisioning Profiles" \
           "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
  [ -d "$dir" ] || continue
  for profile in "$dir"/*.mobileprovision; do
    [ -f "$profile" ] || continue
    if security cms -D -i "$profile" 2>/dev/null | grep -qF "$bundle_suffix"; then
      log "Altes Profil entfernt: $(basename "$profile")"
      rm -f "$profile"
    fi
  done
done

cd "$APP_DIR"
flutter pub get || flutter pub get --offline || fail "flutter pub get"
flutter build ios --release || fail "flutter build ios"

APP_BUNDLE="$APP_DIR/build/ios/iphoneos/Runner.app"
[ -d "$APP_BUNDLE" ] || fail "Build-Ergebnis fehlt: $APP_BUNDLE"

installed=0
for _ in 1 2 3 4 5; do
  if xcrun devicectl device install app --device "$FADEN_DEVICE" "$APP_BUNDLE"; then
    installed=1
    break
  fi
  log "iPhone nicht erreichbar, neuer Versuch in 60 s"
  sleep 60
done
[ "$installed" = 1 ] || fail "Installation auf $FADEN_DEVICE (iPhone im selben WLAN?)"

mkdir -p "$STATE_DIR"
date +%s > "$STAMP"

expiry="$(security cms -D -i "$APP_BUNDLE/embedded.mobileprovision" 2>/dev/null \
  | plutil -extract ExpirationDate raw -o - - 2>/dev/null || echo "unbekannt")"
log "Fertig, Profil gültig bis $expiry"
notify "App erneuert, gültig bis $expiry"
