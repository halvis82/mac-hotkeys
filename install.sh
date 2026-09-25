#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="MacHotkeys"
APP_DIR="$HOME/Applications/$APP_NAME.app"
LABEL="com.halvor.machotkeys"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs"

echo "==> Building"
mkdir -p "$APP_DIR/Contents/MacOS"
swiftc -O -o "$APP_DIR/Contents/MacOS/$APP_NAME" "$HERE"/src/*.swift \
    -framework Cocoa -framework ApplicationServices

cat > "$APP_DIR/Contents/Info.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>Mac Hotkeys</string>
    <key>CFBundleIdentifier</key><string>$LABEL</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLISTEOF

# Prefer a stable signing identity. Ad-hoc signatures change on every build, so macOS treats
# each rebuild as a different app: the Privacy & Security entry silently goes stale, showing as
# enabled while granting nothing. A fixed identity keeps grants valid across rebuilds.
# See README.md for the one-time setup. Matched as a substring of the certificate's name, so
# "Local Codesign" also finds one called, say, "Jane's Local Codesign". Override with SIGN_ID.
SIGN_ID="${SIGN_ID:-Local Codesign}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "==> Signing with stable identity ($SIGN_ID)"
    codesign --force --deep --sign "$SIGN_ID" "$APP_DIR" >/dev/null 2>&1 || true
else
    echo "==> Signing ad-hoc (permissions will need re-granting after each rebuild)"
    codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

# RunAtLoad starts it at every login, KeepAlive restarts it if it ever exits. ProcessType
# Interactive matters for the switcher: left unset, launchd runs an agent as a throttled
# background job, and the delay between a keypress and the agent acting on it grew with it.
echo "==> Installing LaunchAgent"
mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_DIR/Contents/MacOS/$APP_NAME</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>$LOG_DIR/$LABEL.log</string>
    <key>StandardErrorPath</key><string>$LOG_DIR/$LABEL.log</string>
</dict>
</plist>
PLISTEOF

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
for _ in $(seq 1 25); do
    launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1 || break
    /bin/sleep 0.2
done
: > "$LOG_DIR/$LABEL.log"
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl kickstart -k "gui/$UID/$LABEL"

echo "==> Done."
echo "    App:  $APP_DIR"
echo "    Log:  $LOG_DIR/$LABEL.log"
echo ""
echo "    One app now, so permissions are granted once: Accessibility (required),"
echo "    Screen Recording (switcher previews), Full Disk Access (focus state)."
