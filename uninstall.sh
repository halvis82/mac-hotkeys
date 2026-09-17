#!/bin/bash
set -euo pipefail
LABEL="com.halvor.machotkeys"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/MacHotkeys.app"
# older split installs, in case this is an upgrade from those
for OLD in focustoggle fullscreencycle cmdtabswitcher; do
    launchctl bootout "gui/$UID/com.halvor.$OLD" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/com.halvor.$OLD.plist"
done
rm -rf "$HOME/Applications/FocusToggle.app" "$HOME/Applications/FullscreenCycle.app" \
       "$HOME/Applications/CmdTabSwitcher.app"
echo "==> Removed."
