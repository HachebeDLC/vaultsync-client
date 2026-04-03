#!/bin/bash
# VaultSync Autostart Installer for Steam Deck
# Registers VaultSync to start automatically when Desktop Mode launches.
# The app runs in the system tray and stays alive when you switch to Game Mode,
# allowing the Decky plugin to connect to it at localhost:5437.

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
AUTOSTART_DIR="$HOME/.config/autostart"
AUTOSTART_FILE="$AUTOSTART_DIR/vaultsync.desktop"

mkdir -p "$AUTOSTART_DIR"

cat << EOF > "$AUTOSTART_FILE"
[Desktop Entry]
Version=1.0
Name=VaultSync
Comment=Start VaultSync bridge for Decky plugin
Exec=$DIR/VaultSync
Icon=$DIR/data/flutter_assets/assets/vaultsync_icon.png
Terminal=false
Type=Application
Categories=Utility;
X-GNOME-Autostart-enabled=true
EOF

chmod +x "$AUTOSTART_FILE"

echo "Autostart installed. VaultSync will now launch automatically when you enter Desktop Mode."
echo "The app will run in the system tray and remain active when you switch to Game Mode."
echo ""
echo "To remove autostart: rm $AUTOSTART_FILE"
