#!/bin/zsh
# Now Playing installer.
#   ./install.sh                  install/reload the sync agent + menu bar app (signs in to Slack if enabled)
#   ./install.sh login            sign in to Slack again (e.g. after your token expires)
#   ./install.sh enable  github   turn an output on  (slack | slack-tab | github)
#   ./install.sh disable slack    turn an output off (clears the status it set)
#   ./install.sh uninstall        clear statuses, sign out, and remove everything
set -euo pipefail

DIR="${0:A:h}"
SCRIPT="$DIR/now_playing.py"
PY=/usr/bin/python3
LOG="$HOME/Library/Logs/now-playing.log"
AGENTS="$HOME/Library/LaunchAgents"
SYNC_LABEL="com.$USER.now-playing"
BAR_LABEL="com.$USER.now-playing-bar"
BAR_BIN="$DIR/menubar/NowPlayingBar"
# launchd agents can't read ~/Documents, ~/Desktop, etc. (macOS privacy protection), so the
# agents run copies installed here; rerun ./install.sh after pulling updates.
INSTALL_DIR="$HOME/Library/Application Support/now-playing"
APP="$INSTALL_DIR/NowPlaying.app"

unload() { launchctl bootout "gui/$UID/$1" 2>/dev/null || true; }

write_agent() {  # label, interval-or-keepalive, program args...
  local label=$1 mode=$2; shift 2
  local args="" a
  for a in "$@"; do args+="    <string>$a</string>"$'\n'; done
  local schedule
  if [[ $mode == keepalive ]]; then
    # Restart if it crashes, but stay quit if you choose Quit from the menu.
    schedule="  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>"
  else
    schedule="  <key>StartInterval</key><integer>$mode</integer>"
  fi
  cat > "$AGENTS/$label.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
$args  </array>
$schedule
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
  launchctl bootstrap "gui/$UID" "$AGENTS/$label.plist"
}

case "${1:-install}" in
  login)
    exec "$PY" "$SCRIPT" login
    ;;
  enable|disable)
    [[ $# -eq 2 ]] || { echo "usage: $0 $1 slack|slack-tab|github" >&2; exit 2; }
    if [[ $1 == enable && $2 == github ]]; then
      command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh" >&2; exit 1; }
      if ! gh auth status -h github.com 2>/dev/null | grep -q "'user'"; then
        echo "Granting the GitHub CLI the 'user' scope (needed to set your status)…"
        gh auth refresh -h github.com -s user
      fi
    fi
    if [[ $1 == enable && $2 == slack ]] && ! security find-generic-password -s now-playing-slack >/dev/null 2>&1; then
      "$PY" "$SCRIPT" login
    fi
    "$PY" "$SCRIPT" "$1" "$2"
    launchctl kickstart "gui/$UID/$SYNC_LABEL" 2>/dev/null || true
    exit 0
    ;;
  uninstall)
    unload "$BAR_LABEL"; unload "$SYNC_LABEL"
    rm -f "$AGENTS/$BAR_LABEL.plist" "$AGENTS/$SYNC_LABEL.plist"
    for out in slack slack-tab github; do "$PY" "$SCRIPT" disable "$out" >/dev/null; done
    "$PY" "$SCRIPT" logout
    rm -f "${INSTALL_DIR:?}/now_playing.py"
    rm -rf "${INSTALL_DIR:?}/NowPlaying.app"
    echo "Uninstalled."
    exit 0
    ;;
  install) ;;
  *)
    sed -n '2,7p' "$0" | sed 's/^# //' >&2
    exit 2
    ;;
esac

if "$PY" "$SCRIPT" outputs | grep -qE "(: |, )slack(,|$)" && ! security find-generic-password -s now-playing-slack >/dev/null 2>&1; then
  "$PY" "$SCRIPT" login
fi

mkdir -p "$AGENTS" "$INSTALL_DIR"
install -m 755 "$SCRIPT" "$INSTALL_DIR/now_playing.py"
unload "$SYNC_LABEL"
write_agent "$SYNC_LABEL" 20 "$PY" "$INSTALL_DIR/now_playing.py"

unload "$BAR_LABEL"
rm -f "${INSTALL_DIR:?}/NowPlayingBar"  # pre-.app installs
if command -v swiftc >/dev/null && swiftc -O "$DIR"/menubar/*.swift -o "$BAR_BIN" 2>/dev/null; then
  # A real .app bundle (not a bare binary) so macOS shows a proper "Now Playing wants to control
  # Music" prompt and remembers the answer.
  rm -rf "${APP:?}"
  mkdir -p "$APP/Contents/MacOS"
  install -m 755 "$BAR_BIN" "$APP/Contents/MacOS/NowPlayingBar"
  cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.now-playing.menubar</string>
  <key>CFBundleName</key><string>Now Playing</string>
  <key>CFBundleExecutable</key><string>NowPlayingBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Now Playing reads the current song's position and artwork, and sends play, pause and skip, to Music and Spotify.</string>
</dict>
</plist>
EOF
  codesign --force --sign - "$APP" 2>/dev/null
  write_agent "$BAR_LABEL" keepalive "$APP/Contents/MacOS/NowPlayingBar"
  echo "Menu bar app installed (look for the 🎶 icon; click it for the mini player)."
else
  echo "Skipped the menu bar app: needs Xcode command line tools (xcode-select --install), then rerun."
fi

"$PY" "$SCRIPT" outputs
echo "Installed. Logs: $LOG"
