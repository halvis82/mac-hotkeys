#!/bin/bash
set -euo pipefail
LABEL="com.halvor.machotkeys"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/MacHotkeys.app"
echo "==> Removed."
