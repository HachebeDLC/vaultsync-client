#!/bin/bash
# VaultSync Linux/Steam Deck Shortcut Installer
# This script creates a .desktop file so VaultSync appears in your application menu with its icon.

# Get the absolute path of the directory this script is running from
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Define the target path for the .desktop file
DESKTOP_DIR="$HOME/.local/share/applications"
DESKTOP_FILE="$DESKTOP_DIR/vaultsync.desktop"

# Ensure the applications directory exists
mkdir -p "$DESKTOP_DIR"

# Generate the .desktop file with absolute paths based on the current location
cat << EOF > "$DESKTOP_FILE"
[Desktop Entry]
Version=1.0
Name=VaultSync
Comment=High-performance emulator save synchronization
Exec=$DIR/VaultSync
Icon=$DIR/data/flutter_assets/assets/vaultsync_icon.png
Terminal=false
Type=Application
Categories=Utility;Game;
EOF

# Make the shortcut executable
chmod +x "$DESKTOP_FILE"

echo "✅ Success! VaultSync has been added to your applications menu."
echo "You can now find it in your launcher or add it to Steam."
