#!/bin/bash
# Install a LaunchAgent so the widget starts automatically at login.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST="$HOME/Library/LaunchAgents/com.claudeusage.widget.plist"

# Prefer the installed copy in /Applications; fall back to the repo build output.
if [ -x "/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage" ]; then
    APP="/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage"
else
    APP="$DIR/build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage"
    [ -x "$APP" ] || "$DIR/build.sh"
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claudeusage.widget</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null
launchctl load "$PLIST"
echo "Autostart installed → $PLIST"
echo "The widget will now launch automatically at login. Started it now too."

# Uninstall hint:
echo "To remove autostart:  launchctl unload \"$PLIST\" && rm \"$PLIST\""
