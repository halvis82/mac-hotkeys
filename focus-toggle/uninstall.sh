#!/bin/bash
set -euo pipefail

LABEL="com.halvor.focustoggle"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_DIR="$HOME/Applications/FocusToggle.app"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$APP_DIR"

echo "==> Removed."
