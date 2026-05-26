#!/usr/bin/env bash
#
# TRAKKAR.IN installer for Linux.
#
# Downloads the latest AppImage from the GitHub release, drops it in
# ~/Applications, installs an icon and a .desktop launcher, and handles
# the two friction points modern Ubuntu hits:
#   1. missing libfuse2 (Ubuntu 22.04+ ships FUSE 3, AppImages need 2)
#   2. AppArmor restricting unprivileged user namespaces (Ubuntu 24.04+)
#
# Usage:
#   curl -fsSL https://github.com/Jainikpa/timer-apps/releases/latest/download/install-linux.sh | bash
#   # or:
#   bash install-linux.sh
#
set -euo pipefail

readonly REPO="Jainikpa/timer-apps"
readonly APP_NAME="TRAKKAR.IN"
readonly DESKTOP_ID="trakkar"
readonly APPS_DIR="${HOME}/Applications"
readonly DESKTOP_DIR="${HOME}/.local/share/applications"
readonly ICON_DIR="${HOME}/.local/share/icons/hicolor/512x512/apps"

# When run via `curl ... | bash`, stdin is the script body, not the terminal.
# Prompts have to read from /dev/tty directly.
readonly TTY_IN="/dev/tty"

red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[1;34m%s\033[0m\n' "$*"; }
gray()  { printf '\033[2m%s\033[0m\n' "$*"; }

prompt_yn() {
  # Returns 0 (yes) on Y/empty, 1 (no) on N.
  # If we have no tty at all, default to yes.
  local question="$1"
  local answer=""
  if [ -e "$TTY_IN" ]; then
    read -r -p "$question [Y/n] " answer < "$TTY_IN" || answer=""
  fi
  [[ ! "${answer:-Y}" =~ ^[Nn] ]]
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    red "Missing required command: $1"
    exit 1
  fi
}

main() {
  echo
  blue "▶ Installing $APP_NAME"
  echo

  require_command curl

  blue "Fetching latest release info..."
  local url
  url=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep -E '"browser_download_url":' \
    | grep -E '\.AppImage"' \
    | grep -v blockmap \
    | head -1 \
    | sed -E 's/.*"(https:[^"]+)".*/\1/')

  if [ -z "$url" ]; then
    red "Could not find an AppImage in the latest release of ${REPO}."
    red "Check https://github.com/${REPO}/releases/latest"
    exit 1
  fi

  local filename
  filename=$(basename "$url")
  local dest="${APPS_DIR}/${filename}"

  mkdir -p "$APPS_DIR"
  blue "Downloading ${filename}..."
  curl -fL --progress-bar -o "$dest" "$url"
  chmod +x "$dest"

  # libfuse2 — required by the AppImage runtime on Ubuntu 22.04+.
  if ! ldconfig -p 2>/dev/null | grep -q libfuse.so.2; then
    echo
    red "libfuse2 is not installed."
    gray "  AppImages need libfuse2 to mount themselves. Without it the app"
    gray "  exits silently when launched."
    if prompt_yn "Install libfuse2 now (requires sudo)?"; then
      sudo apt-get update -qq
      sudo apt-get install -y libfuse2
    else
      red "Skipping libfuse2 install — the app will not start until you install it."
    fi
  fi

  # AppArmor unprivileged-userns restriction (Ubuntu 24.04+ default).
  # If on, Chromium's sandbox can't run unless we either relax this OR pass
  # --no-sandbox at launch.
  local sandbox_arg="--no-sandbox"
  local restrict_path="/proc/sys/kernel/apparmor_restrict_unprivileged_userns"
  local restrict="0"
  if [ -r "$restrict_path" ]; then
    restrict=$(cat "$restrict_path" 2>/dev/null || echo "0")
  fi
  if [ "$restrict" = "1" ]; then
    echo
    blue "Your system restricts unprivileged user namespaces (Ubuntu 24.04+ default)."
    gray "  Chromium's sandbox needs this to run. Two options:"
    gray "    a) Relax this sysctl (recommended — keeps sandbox enabled)"
    gray "    b) Launch with --no-sandbox (this script will fall back to this)"
    if prompt_yn "Relax the restriction now (persistent, requires sudo)?"; then
      echo 'kernel.apparmor_restrict_unprivileged_userns = 0' \
        | sudo tee /etc/sysctl.d/60-apparmor-namespace.conf >/dev/null
      sudo sysctl --system >/dev/null
      sandbox_arg=""
      green "✓ Restriction relaxed — Chromium sandbox will work."
    else
      gray "  Falling back to --no-sandbox in the launcher entry."
    fi
  fi

  # Icon, extracted from the AppImage so it always matches the version.
  blue "Installing icon..."
  mkdir -p "$ICON_DIR"
  local tmp
  tmp=$(mktemp -d)
  (
    cd "$tmp"
    "$dest" --appimage-extract usr/share/icons/hicolor/0x0/apps/trakkar.png \
      >/dev/null 2>&1 || true
    if [ -f "squashfs-root/usr/share/icons/hicolor/0x0/apps/trakkar.png" ]; then
      cp "squashfs-root/usr/share/icons/hicolor/0x0/apps/trakkar.png" \
        "${ICON_DIR}/${DESKTOP_ID}.png"
    fi
  )
  rm -rf "$tmp"

  # Desktop launcher entry.
  blue "Registering app launcher..."
  mkdir -p "$DESKTOP_DIR"
  local exec_line="${dest}"
  if [ -n "$sandbox_arg" ]; then
    exec_line="${dest} ${sandbox_arg}"
  fi
  cat > "${DESKTOP_DIR}/${DESKTOP_ID}.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=${APP_NAME}
Comment=Time tracking and productivity monitoring
Exec=${exec_line} %U
Icon=${DESKTOP_ID}
Terminal=false
StartupWMClass=${APP_NAME}
Categories=Utility;
EOF
  chmod +x "${DESKTOP_DIR}/${DESKTOP_ID}.desktop"

  # Refresh menu + icon caches so the entry shows up immediately.
  command -v update-desktop-database >/dev/null 2>&1 \
    && update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
  command -v gtk-update-icon-cache >/dev/null 2>&1 \
    && gtk-update-icon-cache -f -t "${HOME}/.local/share/icons/hicolor/" \
    2>/dev/null || true

  echo
  green "✓ ${APP_NAME} installed."
  echo
  gray "  Location: ${dest}"
  gray "  Launch:   open your apps menu (Super key) and search for Trakkar"
  echo
  gray "  Auto-update is enabled; the app checks for new versions periodically."
}

main "$@"
