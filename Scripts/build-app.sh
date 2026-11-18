#!/bin/bash
# Builds TopLayer.app, signs it, and installs it into /Applications.
#
#   Scripts/build-app.sh            build, sign, install
#   Scripts/build-app.sh --launch   ...and start it (quitting any running copy first)
#
# Signing uses the first of these that exists:
#   1. the identity named in TOPLAYER_SIGN_IDENTITY
#   2. a certificate Apple issued to you, in your keychain: "Developer ID Application",
#      then "Apple Development" (Xcode creates one when you sign in with an Apple account)
#   3. a self-signed certificate named "TopLayer Local Signing"
#   4. none: an ad-hoc signature
# macOS remembers what you allowed an app to do (a keychain item, a privacy permission)
# by who signed it. With 1 to 3 that stays the same from build to build. With an Apple
# certificate the system can also check the signature back to Apple, which a self-signed
# one can't offer. Ad-hoc signed, every build is a different app and is asked again.
set -euo pipefail
cd "$(dirname "$0")/.."

# Pick the signing identity. An Apple certificate is used by its fingerprint, so that two
# certificates with similar names can't be confused, and described without its name,
# which holds an email address.
LOCAL_IDENTITY="TopLayer Local Signing"
IDENTITY="-"
SIGNED_AS="ad-hoc (no stable identity)"
if [ -n "${TOPLAYER_SIGN_IDENTITY:-}" ]; then
  IDENTITY="$TOPLAYER_SIGN_IDENTITY"
  SIGNED_AS="the identity in TOPLAYER_SIGN_IDENTITY"
else
  valid="$(security find-identity -p codesigning -v 2>/dev/null || true)"
  for kind in "Developer ID Application" "Apple Development"; do
    fingerprint="$(printf '%s\n' "$valid" | awk -v kind="\"$kind: " 'index($0, kind) { print $2; exit }')"
    if [ -n "$fingerprint" ]; then
      IDENTITY="$fingerprint"
      SIGNED_AS="your $kind certificate"
      break
    fi
  done
  if [ "$IDENTITY" = "-" ] && security find-identity -p codesigning 2>/dev/null | grep -q "\"$LOCAL_IDENTITY\""; then
    IDENTITY="$LOCAL_IDENTITY"
    SIGNED_AS="$LOCAL_IDENTITY (self-signed)"
  fi
fi
APP="build/TopLayer.app"
DEST="/Applications/TopLayer.app"
VERSION="0.1.0"

echo "==> building (release)"
swift build -c release 2>&1 | grep -E 'error|warning: unre|Compiling|Build complete' | tail -3

echo "==> icon"
if [ ! -f Resources/AppIcon.icns ] || [ Scripts/make-icon.swift -nt Resources/AppIcon.icns ]; then
  work="$(mktemp -d)"
  swift Scripts/make-icon.swift "$work/icon.png" >/dev/null
  mkdir -p "$work/AppIcon.iconset" Resources
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$work/icon.png" --out "$work/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$work/icon.png" --out "$work/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$work/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$work"
fi

echo "==> bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp .build/release/TopLayer "$APP/Contents/MacOS/TopLayer"
cp .build/release/TopLayerLink "$APP/Contents/Resources/bin/toplayer-link"
cp Hooks/toplayer-hook.sh Hooks/toplayer-permission.sh "$APP/Contents/Resources/bin/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>app.toplayer.TopLayer</string>
  <key>CFBundleName</key><string>TopLayer</string>
  <key>CFBundleDisplayName</key><string>TopLayer</string>
  <key>CFBundleExecutable</key><string>TopLayer</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> signing with: $SIGNED_AS"
# The link tool gets an identifier of its own under the app's, not one taken from its
# file name.
codesign --force --sign "$IDENTITY" --identifier app.toplayer.TopLayer.link "$APP/Contents/Resources/bin/toplayer-link"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP" && echo "    signature ok"
team="$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[ -n "$team" ] && [ "$team" != "not set" ] && echo "    team $team"

echo "==> installing to $DEST"
if [ "${1:-}" = "--launch" ]; then
  pkill -x TopLayer 2>/dev/null || true
  pkill -f '\.build/debug/TopLayer$' 2>/dev/null || true
  sleep 0.5
fi
rm -rf "$DEST"
cp -R "$APP" "$DEST"

# The hook scripts and link tool that Claude and Codex call live outside the bundle,
# at a path that never moves.
mkdir -p "$HOME/.toplayer/bin"
chmod 700 "$HOME/.toplayer"
# Each file is copied beside its destination and then moved over it. Writing a new
# build into the existing file would keep the file's identity, and macOS remembers a
# signed program's signature by that identity: the next run of toplayer-link would be
# checked against the old build's signature and killed (exit 137, no output).
for name in toplayer-hook.sh toplayer-permission.sh toplayer-link; do
  cp "$APP/Contents/Resources/bin/$name" "$HOME/.toplayer/bin/.$name.new"
  chmod 755 "$HOME/.toplayer/bin/.$name.new"
  mv -f "$HOME/.toplayer/bin/.$name.new" "$HOME/.toplayer/bin/$name"
done

if [ "${1:-}" = "--launch" ]; then
  echo "==> launching"
  open "$DEST"
fi
echo "done: $DEST (version $VERSION)"
