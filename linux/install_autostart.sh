#!/bin/bash
# VaultSync Installer for Steam Deck / Linux
#
# Sets up two things:
#   1. systemd user service — starts the headless bridge daemon at login,
#      persists across Desktop↔Game Mode switches, is what the Decky plugin
#      actually connects to (localhost:5437).
#   2. .desktop autostart — opens the VaultSync GUI in Desktop Mode so the
#      user can configure the server URL, log in, and manage sync settings.
#      The GUI is NOT required for Decky sync to work.

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BRIDGE_SCRIPT="$DIR/vaultsync_bridge.py"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SYSTEMD_USER_DIR/vaultsync-bridge.service"
AUTOSTART_DIR="$HOME/.config/autostart"
AUTOSTART_FILE="$AUTOSTART_DIR/vaultsync.desktop"

# --- Check dependencies ---
if ! command -v python3 &>/dev/null; then
    echo "Error: python3 is required but not found."
    exit 1
fi

# Use a dedicated venv — avoids pip3/pip not-found and "externally managed
# environment" errors on Steam Deck (Arch) and modern Debian/Ubuntu systems.
VENV_DIR="$HOME/.local/share/vaultsync/venv"
echo "Setting up Python venv at $VENV_DIR..."
python3 -m venv "$VENV_DIR" || { echo "Error: failed to create venv (try: python3 -m ensurepip)"; exit 1; }

echo "Installing Python dependencies..."
"$VENV_DIR/bin/pip" install --quiet aiohttp requests cryptography \
    || { echo "Error: pip install failed"; exit 1; }

PYTHON_BIN="$VENV_DIR/bin/python3"
chmod +x "$BRIDGE_SCRIPT"

# -----------------------------------------------------------------------
# 1. systemd user service (bridge daemon — headless, works in Game Mode)
# -----------------------------------------------------------------------
mkdir -p "$SYSTEMD_USER_DIR"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=VaultSync Decky Bridge
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$PYTHON_BIN $BRIDGE_SCRIPT
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable vaultsync-bridge.service
systemctl --user restart vaultsync-bridge.service

if systemctl --user is-active --quiet vaultsync-bridge.service; then
    echo "Bridge service started successfully."
else
    echo "Warning: bridge service did not start. Check: journalctl --user -u vaultsync-bridge"
fi

# -----------------------------------------------------------------------
# 2. Desktop autostart (opens GUI in Desktop Mode for configuration)
# -----------------------------------------------------------------------
mkdir -p "$AUTOSTART_DIR"

cat > "$AUTOSTART_FILE" <<EOF
[Desktop Entry]
Version=1.0
Name=VaultSync
Comment=Open VaultSync for configuration (bridge runs automatically via systemd)
Exec=$DIR/VaultSync
Icon=$DIR/data/flutter_assets/assets/vaultsync_icon.png
Terminal=false
Type=Application
Categories=Utility;
X-GNOME-Autostart-enabled=true
EOF

chmod +x "$AUTOSTART_FILE"

# -----------------------------------------------------------------------
# 3. Decky Loader plugin (optional — only if Decky is installed)
# -----------------------------------------------------------------------
DECKY_PLUGINS_DIR="$HOME/homebrew/plugins"
PLUGIN_SRC="$DIR/decky_plugin"
PLUGIN_DEST="$DECKY_PLUGINS_DIR/VaultSync"

if [ -d "$DECKY_PLUGINS_DIR" ] && [ -d "$PLUGIN_SRC" ]; then
    echo "Installing Decky plugin to $PLUGIN_DEST..."
    rm -rf "$PLUGIN_DEST"
    cp -r "$PLUGIN_SRC" "$PLUGIN_DEST"
    echo "Decky plugin installed. Restart Decky Loader to activate it."
elif [ ! -d "$DECKY_PLUGINS_DIR" ]; then
    echo "Decky Loader not found — skipping plugin install."
    echo "  To install later: copy $PLUGIN_SRC to ~/homebrew/plugins/VaultSync/"
elif [ ! -d "$PLUGIN_SRC" ]; then
    echo "Warning: decky_plugin directory not found in bundle — skipping."
fi

echo ""
echo "Setup complete."
echo "  Bridge service: systemctl --user status vaultsync-bridge"
echo "  Bridge logs:    journalctl --user -u vaultsync-bridge -f"
echo "  GUI autostart:  opens VaultSync in Desktop Mode for configuration"
echo ""
echo "The Decky plugin will work in Game Mode without opening the GUI."
