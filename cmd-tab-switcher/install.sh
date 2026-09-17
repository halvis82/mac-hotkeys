#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="CmdTabSwitcher"
APP_DIR="$HOME/Applications/$APP_NAME.app"
LABEL="com.halvor.cmdtabswitcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs"

echo "==> Building"
mkdir -p "$APP_DIR/Contents/MacOS"
swiftc -O -o "$APP_DIR/Contents/MacOS/$APP_NAME" \
    "$HERE/src/Spaces.swift" "$HERE/src/Model.swift" "$HERE/src/Thumbnails.swift" \
    "$HERE/src/Overlay.swift" "$HERE/src/WindowActions.swift" "$HERE/src/main.swift" \
    -framework Cocoa -framework ApplicationServices

cat > "$APP_DIR/Contents/Info.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>Cmd Tab Switcher</string>
    <key>CFBundleIdentifier</key><string>$LABEL</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLISTEOF

codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

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
echo "    Needs Accessibility, Input Monitoring AND Screen Recording - see README.md."
echo "    Without Screen Recording the tiles render blank."
