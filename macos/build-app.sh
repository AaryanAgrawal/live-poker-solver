#!/bin/bash
# Build, assemble, sign and install Live Poker Solver.app
set -e
cd "$(dirname "$0")"
swift build -c release
test -f .build/release/LivePokerSolver || { echo BUILD FAILED; exit 1; }
APP="../dist-native/Live Poker Solver.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/LivePokerSolver "$APP/Contents/MacOS/Live Poker Solver"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Live Poker Solver</string>
<key>CFBundleDisplayName</key><string>Live Poker Solver</string>
<key>CFBundleIdentifier</key><string>com.aaryan.livepokersolver</string>
<key>CFBundleVersion</key><string>2.0</string>
<key>CFBundleShortVersionString</key><string>2.0</string>
<key>CFBundleExecutable</key><string>Live Poker Solver</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
./make-signing-identity.sh >/dev/null 2>&1 || true
security unlock-keychain -p "solver-signing-local" "$HOME/Library/Keychains/solver-signing.keychain-db" 2>/dev/null || true
KC="$HOME/Library/Keychains/solver-signing.keychain-db"
HASH=$(security find-identity -p codesigning "$KC" 2>/dev/null | grep -oE "[A-F0-9]{40}" | head -1)
if [ -n "$HASH" ]; then codesign --force --deep --sign "$HASH" --keychain "$KC" "$APP"; else codesign --force --deep --sign - "$APP"; fi
mkdir -p ~/Applications
rm -rf ~/Applications/"Live Poker Solver.app"
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/Live Poker Solver.app"
