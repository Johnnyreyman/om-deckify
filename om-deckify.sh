#!/bin/bash

# OpenMandriva Deckify Script for Mixed X11/Wayland - Plasma on X11, Gamescope on Wayland
# Author: Grok (based on unlbslk/arch-deckify)
# Run as non-root user. Backup your system first!

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'  # No Color

echo -e "${GREEN}OpenMandriva Deckify Installer (Mixed X11/Wayland)${NC}"
echo "This sets up Plasma on X11 (Desktop Mode) and Gamescope on Wayland (Gaming Mode)."
echo "Prerequisites: KDE Plasma with SDDM on X11, sudo access."
echo "NVIDIA: Enable non-free repo (sudo dnf config-manager --set-enabled rock-x86_64-non-free) and add 'nvidia-drm.modeset=1' to kernel parameters."
echo "If black screen occurs in Gaming Mode, check /tmp/gamescope-session.log or try X11 mode."
echo "If session switching fails, check /tmp/steamos-session-select.log."

# Prompt for username
read -p "Enter your username (for autologin to X11 Plasma): " USERNAME
if [ -z "$USERNAME" ]; then
    echo -e "${RED}Error: Username cannot be empty. Exiting.${NC}"
    exit 1
fi
# Validate username exists
id "$USERNAME" &> /dev/null || { echo -e "${RED}Error: User '$USERNAME' does not exist. Please create the user first.${NC}"; exit 1; }

# Automatically detect default desktop session
echo -e "${YELLOW}Detecting default X11 desktop session...${NC}"
# Check for common KDE Plasma session files
for session in plasmax11 plasma-x11 plasma; do
    if [ -f "/usr/share/xsessions/$session.desktop" ]; then
        DEFAULT_SESSION="$session"
        break
    fi
done

# If no session detected, prompt user with available sessions
if [ -z "$DEFAULT_SESSION" ]; then
    echo "No KDE Plasma session detected in /usr/share/xsessions/."
    echo "Available X11 sessions:"
    ls /usr/share/xsessions/ | grep -E '\.desktop$' | sed 's/\.desktop$//' || echo "No sessions found."
    read -p "Enter default desktop session (e.g., 'plasmax11' or 'plasma-x11' for X11 KDE): " DEFAULT_SESSION
    if [ -z "$DEFAULT_SESSION" ]; then
        echo -e "${RED}Error: Default session cannot be empty. Exiting.${NC}"
        exit 1
    fi
    # Validate user-provided session
    if [ ! -f "/usr/share/xsessions/$DEFAULT_SESSION.desktop" ]; then
        echo -e "${RED}Error: Session '$DEFAULT_SESSION.desktop' not found in /usr/share/xsessions."
        echo "Try installing KDE Plasma: sudo dnf install plasma-desktop sddm"
        echo "Exiting.${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}Detected default session: $DEFAULT_SESSION${NC}"
fi

# Update system
echo -e "${YELLOW}Updating system...${NC}"
sudo dnf clean all
sudo dnf update -y || { echo -e "${RED}Failed to update system. Check your internet or repositories.${NC}"; exit 1; }

# Install core packages (OM Wiki: task-plasma6-wayland + Steam Deck essentials)
echo -e "${YELLOW}Installing packages (using OM Wiki Wayland task + Steam Deck tools)...${NC}"
sudo dnf install -y --refresh \
    task-plasma6-wayland \
    steam \
    gamescope \
    mangohud \
    wget \
    bluez \
    bluetoothctl \
    jq \
    || { echo -e "${RED}Failed to install required packages. Ensure repositories are enabled (incl. non-free for NVIDIA).${NC}"; exit 1; }

# Enable services
sudo systemctl enable sddm bluetooth

# Create directories
mkdir -p ~/om-deckify
cd ~/om-deckify

# Create Gamescope session files
echo -e "${YELLOW}Setting up Gamescope session on Wayland...${NC}"

# gamescope-session script (/usr/bin/gamescope-session)
sudo tee /usr/bin/gamescope-session > /dev/null << 'EOF'
#!/bin/bash
# Adapted from ChimeraOS/SteamOS gamescope-session, for Wayland
# If Wayland fails (black screen), try X11 mode by replacing the gamescope line with:
# gamescope -b -W 1920 -H 1080 -r 60 steam -steamdeck -steamos3 -gamepadui
# Debug logs: /tmp/gamescope-session.log

# Environment for Steam Deck-like experience
export STEAM_GAMESCOPE_VRR_SUPPORTED=1
export MANGOHUD=1  # Enable FPS overlay
export XDG_SESSION_TYPE=wayland

# Log for debugging
echo "Starting Gamescope session at $(date)" > /tmp/gamescope-session.log
echo "User: $USER" >> /tmp/gamescope-session.log
echo "Checking Wayland support..." >> /tmp/gamescope-session.log
if [ ! -S "$XDG_RUNTIME_DIR/wayland-0" ]; then
    echo "Error: Wayland socket not found. Ensure Wayland is supported." >> /tmp/gamescope-session.log
    exit 1
fi
echo "Launching Gamescope with Steam..." >> /tmp/gamescope-session.log
gamescope -W 1920 -H 1080 -r 60 steam -steamdeck -steamos3 -gamepadui 2>> /tmp/gamescope-session.log
if [ $? -ne 0 ]; then
    echo "Gamescope failed to start. Check /tmp/gamescope-session.log for details." >&2
    exit 1
fi
EOF
sudo chmod +x /usr/bin/gamescope-session

# .desktop file for Wayland sessions
sudo mkdir -p /usr/share/wayland-sessions/
sudo tee /usr/share/wayland-sessions/gamescope-session.desktop > /dev/null << EOF
[Desktop Entry]
Name=Gaming Mode (Gamescope Wayland)
Comment=Steam Gaming Session on Wayland
Exec=/usr/bin/gamescope-session
TryExec=/usr/bin/gamescope-session
Type=Application
DesktopNames=Steam
Keywords=steam;deck;gaming;
EOF

# steamos-session-select script
sudo tee /usr/bin/steamos-session-select > /dev/null << 'EOF'
#!/bin/bash
# Switch sessions (kills current and restarts SDDM)
# Debug logs: /tmp/steamos-session-select.log

# Log for debugging
echo "Starting steamos-session-select at $(date)" > /tmp/steamos-session-select.log
echo "User: $USER, Command: $1" >> /tmp/steamos-session-select.log

# Check if SDDM is running
if ! systemctl is-active --quiet sddm; then
    echo "Error: SDDM is not running. Start SDDM with 'sudo systemctl start sddm'." | tee -a /tmp/steamos-session-select.log
    exit 1
fi

# Get current session ID for the user
SESSION_ID=$(loginctl list-sessions --no-legend | grep "$USER" | grep -E 'seat[0-9]+' | awk '{print $1}' | head -n 1)
if [ -z "$SESSION_ID" ]; then
    echo "Error: Could not determine current session ID for user $USER. Check 'loginctl list-sessions'." | tee -a /tmp/steamos-session-select.log
    exit 1
fi
echo "Detected session ID: $SESSION_ID" >> /tmp/steamos-session-select.log

case "$1" in
  "desktop")
    echo "Switching to Desktop Mode (X11)..." | tee -a /tmp/steamos-session-select.log
    loginctl terminate-session "$SESSION_ID" 2>>/tmp/steamos-session-select.log || { echo "Failed to terminate session $SESSION_ID" | tee -a /tmp/steamos-session-select.log; exit 1; }
    sleep 2  # Wait for session to terminate
    sudo systemctl restart sddm 2>>/tmp/steamos-session-select.log || { echo "Failed to restart SDDM" | tee -a /tmp/steamos-session-select.log; exit 1; }
    ;;
  "gamescope")
    echo "Switching to Gaming Mode (Wayland)..." | tee -a /tmp/steamos-session-select.log
    loginctl terminate-session "$SESSION_ID" 2>>/tmp/steamos-session-select.log || { echo "Failed to terminate session $SESSION_ID" | tee -a /tmp/steamos-session-select.log; exit 1; }
    sleep 2  # Wait for session to terminate
    sudo systemctl restart sddm 2>>/tmp/steamos-session-select.log || { echo "Failed to restart SDDM" | tee -a /tmp/steamos-session-select.log; exit 1; }
    ;;
  *)
    echo "Usage: steamos-session-select [desktop|gamescope]" | tee -a /tmp/steamos-session-select.log
    exit 1
    ;;
esac
EOF
sudo chmod +x /usr/bin/steamos-session-select

# Configure SDDM
echo -e "${YELLOW}Configuring SDDM for mixed X11/Wayland...${NC}"
sudo mkdir -p /etc/sddm.conf.d/
sudo tee /etc/sddm.conf.d/zz-steamos.conf > /dev/null << EOF
[Autologin]
User=${USERNAME}
Session=${DEFAULT_SESSION}.desktop
Relogin=true

[General]
DisplayServer=x11  # SDDM runs on X11, but can launch Wayland sessions

[Theme]
Current=breeze
EOF

# Add sudoers rule
echo -e "${YELLOW}Adding sudoers rule...${NC}"
sudo tee /etc/sudoers.d/steamos > /dev/null << EOF
${USERNAME} ALL=(ALL) NOPASSWD: /usr/bin/steamos-session-select, /usr/bin/loginctl, /usr/bin/systemctl restart sddm
EOF
sudo chmod 440 /etc/sudoers.d/steamos

# Udev rule for backlight
sudo tee /etc/udev/rules.d/99-steamos-backlight.rules > /dev/null << 'EOF'
ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chmod 666 /sys/class/backlight/%k/brightness"
EOF
sudo udevadm control --reload-rules

# Create shortcuts and update script
echo -e "${YELLOW}Creating shortcuts...${NC}"

# Desktop shortcut for Gaming Mode (Wayland)
tee ~/.local/share/applications/steamos-gaming.desktop > /dev/null << EOF
[Desktop Entry]
Name=Gaming Mode (Wayland)
Exec=steamos-session-select gamescope
Icon=steam
Terminal=false
Type=Application
Categories=Game;
EOF

# Desktop shortcut for Desktop Mode (X11)
tee ~/.local/share/applications/steamos-desktop.desktop > /dev/null << EOF
[Desktop Entry]
Name=Desktop Mode (X11)
Exec=steamos-session-select desktop
Icon=plasma
Terminal=false
Type=Application
Categories=System;
EOF

# Desktop shortcut for Return to Gaming Mode (SteamOS-like)
tee ~/.local/share/applications/return-to-gaming-mode.desktop > /dev/null << EOF
[Desktop Entry]
Name=Return to Gaming Mode
Exec=steamos-session-select gamescope
Icon=steam
Terminal=false
Type=Application
Categories=Game;
Comment=Switch to Gaming Mode (Wayland) like SteamOS
EOF

# Copy Return to Gaming Mode shortcut to Desktop
mkdir -p ~/Desktop
cp ~/.local/share/applications/return-to-gaming-mode.desktop ~/Desktop/
chmod +x ~/Desktop/return-to-gaming-mode.desktop

# System update script
tee ~/om-deckify/system_update.sh > /dev/null << 'EOF'
#!/bin/bash
echo "Updating OpenMandriva..."
sudo dnf clean all;dnf clean all;sudo dnf distro-sync --refresh -y
echo "Update complete. Reboot recommended."
EOF
chmod +x ~/om-deckify/system_update.sh

echo -e "${GREEN}Installation complete!${NC}"
echo "Reboot and select 'Gaming Mode (Gamescope Wayland)' at SDDM for Wayland gaming."
echo "Autologin defaults to X11 Plasma ($DEFAULT_SESSION). Switch to Gaming Mode via 'Return to Gaming Mode' desktop shortcut or 'steamos-session-select gamescope'."
echo "If black screen occurs, check /tmp/gamescope-session.log or try X11 mode in /usr/bin/gamescope-session."
echo "If session switching fails, check /tmp/steamos-session-select.log."
echo "Uninstall: sudo rm /usr/bin/gamescope-session /usr/bin/steamos-session-select /etc/sddm.conf.d/zz-steamos.conf /etc/sudoers.d/steamos /etc/udev/rules.d/99-steamos-backlight.rules; rm -rf ~/om-deckify ~/.local/share/applications/steamos-*.desktop ~/.local/share/applications/return-to-gaming-mode.desktop ~/Desktop/return-to-gaming-mode.desktop"
read -p "Install Decky Loader? (y/n) " user_response
  case "$user_response" in
    y|Y ) print_green "Installing Decky Loader";;
    n|N ) print_green "Exiting..." ; exit ;;
  esac
curl -L https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/install_release.sh | sh
