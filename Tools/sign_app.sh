#!/bin/bash
# Signs MFExplorer.app with the fixed own certificate "MFExplorer Code Signing" (login keychain).
# Why: macOS ties permissions (Full Disk Access, Downloads, Desktop …) to the app's signature.
# With a fixed certificate every new version keeps the same identity, so users don't have to
# allow everything again after each update.
#
# Usage: Tools/sign_app.sh <path/to/MFExplorer.app>
set -euo pipefail

APP="${1:?Pfad zur App fehlt}"
CERT_NAME="MFExplorer Code Signing"

# The certificate is self-made (not from Apple), so macOS lists it as "not trusted" –
# signing works anyway when we address it by its fingerprint.
ID=$(security find-identity -p codesigning | grep "\"$CERT_NAME\"" | head -1 | awk '{print $2}')
[ -n "$ID" ] || { echo "Zertifikat \"$CERT_NAME\" nicht im Schlüsselbund gefunden."; exit 1; }

sign() { codesign --force --timestamp=none --preserve-metadata=entitlements -s "$ID" "$1"; }

# Inside out: Sparkle's helpers first, then the framework, then the app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [ -d "$SPARKLE" ]; then
  for part in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
    [ -e "$SPARKLE/$part" ] && sign "$SPARKLE/$part"
  done
  sign "$APP/Contents/Frameworks/Sparkle.framework"
fi
sign "$APP"

codesign --verify --deep --strict "$APP"
echo "→ Unterschrieben mit \"$CERT_NAME\""
