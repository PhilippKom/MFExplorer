#!/bin/bash
# Publishes a new MFExplorer version in one go:
#   build → ZIP → sign for Sparkle → GitHub release → appcast.xml (so installed apps see the update).
#
# Usage:   Tools/release.sh <version> <notes.md>
# Example: Tools/release.sh 1.2 /tmp/notes.md
#
# notes.md: short German release notes in Markdown ("- " lines become a list).
# Needs: Xcode, gh (logged in), the Sparkle signing key "mfexplorer" in the keychain.
set -euo pipefail

VERSION="${1:?Version fehlt, z. B. 1.2}"
NOTES="${2:?Datei mit Änderungsnotizen fehlt}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
PROJECT=MFExplorer.xcodeproj/project.pbxproj
PACKAGES="$ROOT/build/SourcePackages"
ZIP="dist/MFExplorer-$VERSION.zip"
URL="https://github.com/PhilippKom/MFExplorer/releases/download/v$VERSION/MFExplorer-$VERSION.zip"

[ -f "$NOTES" ] || { echo "Notizen-Datei nicht gefunden: $NOTES"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Es gibt ungesicherte Änderungen. Bitte erst committen."; exit 1; }
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "Version $VERSION gibt es schon."; exit 1; }

# 1. Version and build number (the build number must always go up – Sparkle compares it)
OLD_BUILD=$(grep -m1 "CURRENT_PROJECT_VERSION = " "$PROJECT" | sed 's/[^0-9]//g')
CURRENT_VERSION=$(grep -m1 "MARKETING_VERSION = " "$PROJECT" | sed 's/.*= \(.*\);/\1/')
if [ "$CURRENT_VERSION" = "$VERSION" ]; then BUILD=$OLD_BUILD; else BUILD=$((OLD_BUILD + 1)); fi
sed -i '' "s/MARKETING_VERSION = .*;/MARKETING_VERSION = $VERSION;/; s/CURRENT_PROJECT_VERSION = .*;/CURRENT_PROJECT_VERSION = $BUILD;/" "$PROJECT"
echo "→ Version $VERSION (Build $BUILD)"

# 2. Build
xcodebuild -resolvePackageDependencies -project MFExplorer.xcodeproj -clonedSourcePackagesDirPath "$PACKAGES" >/dev/null
xcodebuild -project MFExplorer.xcodeproj -target MFExplorer -configuration Release \
  SYMROOT="$ROOT/build" OBJROOT="$ROOT/build/obj" -clonedSourcePackagesDirPath "$PACKAGES" build | grep -E "error|BUILD"
codesign --verify --deep build/Release/MFExplorer.app

# 3. ZIP + Sparkle signature
mkdir -p dist
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Release/MFExplorer.app "$ZIP"
SIGNATURE=$("$PACKAGES/artifacts/sparkle/Sparkle/bin/sign_update" --account mfexplorer "$ZIP")
echo "→ Signiert: $SIGNATURE"

# 4. Commit the version number, push, create the GitHub release with the ZIP
git commit -qam "Version $VERSION"
git push -q
gh release create "v$VERSION" "$ZIP" --title "Version $VERSION" --notes-file "$NOTES"

# 5. Add the new version to appcast.xml – only now, so the download already exists
python3 - "$VERSION" "$BUILD" "$URL" "$SIGNATURE" "$NOTES" <<'PY'
import sys, html, email.utils
version, build, url, signature, notes_file = sys.argv[1:]
lines = open(notes_file, encoding="utf-8").read().strip().splitlines()
parts, in_list = [], False
for line in lines:
    line = line.strip()
    if line.startswith("- "):
        if not in_list: parts.append("<ul>"); in_list = True
        parts.append("<li>" + html.escape(line[2:]) + "</li>")
    else:
        if in_list: parts.append("</ul>"); in_list = False
        if line.startswith("#"): parts.append("<h3>" + html.escape(line.lstrip("# ")) + "</h3>")
        elif line: parts.append("<p>" + html.escape(line) + "</p>")
if in_list: parts.append("</ul>")
item = f"""    <item>
      <title>Version {version}</title>
      <pubDate>{email.utils.formatdate(localtime=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[{''.join(parts).replace('**', '')}]]></description>
      <enclosure url="{url}" type="application/octet-stream" {signature} />
    </item>
"""
path = "appcast.xml"
text = open(path, encoding="utf-8").read()
marker = "    <!-- Neue Versionen fügt Tools/release.sh hier oben ein. -->\n"
assert marker in text, "Markierung in appcast.xml fehlt"
open(path, "w", encoding="utf-8").write(text.replace(marker, marker + item, 1))
PY
git commit -qam "appcast: Version $VERSION"
git push -q
echo "✓ Version $VERSION ist veröffentlicht. Installierte Apps finden das Update beim nächsten Suchen."
