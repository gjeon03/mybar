#!/bin/bash
# Builds MyBar in release mode and installs it into /Applications, replacing
# (and restarting) a running copy. Usage: scripts/install.sh
set -euo pipefail

cd "$(dirname "$0")/.."
scripts/build-app.sh release

target="/Applications/MyBar.app"
if pgrep -x MyBar >/dev/null; then
  # Quit gracefully so items shown temporarily are put back first.
  osascript -e 'tell application id "dev.gimbap.mybar" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do pgrep -x MyBar >/dev/null || break; sleep 0.2; done
  pkill -x MyBar || true
fi
rm -rf "$target"
ditto build/MyBar.app "$target"
# Refresh the icon in Finder and the Dock.
touch "$target"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target"
open "$target"
echo "Installed $target"
