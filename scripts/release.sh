#!/usr/bin/env bash
# scripts/release.sh
# Build, sign for Sparkle, package, generate appcast, tag, and create the
# GitHub release. Run after bumping the marketing version.
#
# Usage: scripts/release.sh <version>
#   e.g. scripts/release.sh 2.7.0
#
# Requirements:
#   - Sparkle's `sign_update` and `generate_appcast` binaries (auto-located
#     from DerivedData)
#   - gh CLI logged in
#   - Sparkle EdDSA private key in Keychain (run generate_keys once)
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version>"
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/ClaudeNotch-baanmkkvtjtxlvengytgbjmxhqha"
BUILT_APP="$DERIVED/Build/Products/Release/Claude Notch.app"
BUILT_SAVER="$DERIVED/Build/Products/Release/Claude Notch Velion.saver"
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"

cd "$REPO_ROOT"

echo "▸ Building Release configuration…"
xcodebuild -project ClaudeNotch.xcodeproj -scheme ClaudeNotch \
  -configuration Release build > /tmp/cn-build.log 2>&1 || {
    echo "Build failed. Last 30 lines:"
    tail -30 /tmp/cn-build.log
    exit 1
}
xcodebuild -project ClaudeNotch.xcodeproj -scheme ClaudeNotchSaver \
  -configuration Release build > /tmp/cn-saver-build.log 2>&1 || {
    echo "Saver build failed. Last 30 lines:"
    tail -30 /tmp/cn-saver-build.log
    exit 1
}

echo "▸ Packaging artifacts…"
mkdir -p dist
rm -rf "dist/Claude Notch.app" "dist/Claude Notch Velion.saver"
cp -R "$BUILT_APP" dist/
cp -R "$BUILT_SAVER" dist/

APP_ZIP="ClaudeNotch-v${VERSION}.zip"
SAVER_ZIP="ClaudeNotchVelion-v${VERSION}.saver.zip"
( cd dist && /usr/bin/ditto -c -k --sequesterRsrc --keepParent \
    "Claude Notch.app" "$APP_ZIP" )
( cd dist && /usr/bin/ditto -c -k --sequesterRsrc --keepParent \
    "Claude Notch Velion.saver" "$SAVER_ZIP" )

echo "▸ Signing $APP_ZIP for Sparkle…"
SIG_OUTPUT=$("$SPARKLE_BIN/sign_update" "dist/$APP_ZIP")
echo "Sparkle signature: $SIG_OUTPUT"

echo "▸ Generating appcast.xml…"
# Sparkle's generate_appcast scans a directory of zips and produces an
# appcast.xml referencing them. We point it at dist/, where every zip
# from previous releases also lives, so the cast accumulates entries
# rather than overwriting on each release.
"$SPARKLE_BIN/generate_appcast" \
  --link "https://github.com/arratiabenjamin/claude-notch" \
  --download-url-prefix "https://github.com/arratiabenjamin/claude-notch/releases/download/v${VERSION}/" \
  dist/

# generate_appcast writes appcast.xml inside dist/. Copy it to repo root so
# raw.githubusercontent.com/.../main/appcast.xml resolves correctly.
cp "dist/appcast.xml" "appcast.xml"

echo "▸ Computing SHA256 for the Homebrew cask…"
APP_SHA=$(shasum -a 256 "dist/$APP_ZIP" | awk '{print $1}')
echo "  $APP_ZIP sha256: $APP_SHA"

echo
echo "▸ Next steps (manual):"
echo "   1. Review appcast.xml diff and commit it."
echo "   2. git tag v${VERSION} && git push origin v${VERSION}"
echo "   3. gh release create v${VERSION} \\"
echo "        \"dist/$APP_ZIP#Claude Notch.app (zipped)\" \\"
echo "        \"dist/$SAVER_ZIP#Claude Notch Velion.saver (zipped)\" \\"
echo "        --title \"v${VERSION}\" --notes-file dist/notes.md"
echo "   4. Update homebrew-claude-notch/Casks/claude-notch.rb:"
echo "        version \"${VERSION}\""
echo "        sha256 \"${APP_SHA}\""
echo "   5. Push the tap update."
