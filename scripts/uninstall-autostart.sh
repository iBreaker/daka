#!/bin/zsh
set -euo pipefail

LABEL="local.daka.menu"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
    launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
fi

rm -f "$PLIST"

echo "Daka autostart uninstalled."
