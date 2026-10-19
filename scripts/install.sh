#!/bin/bash
# Pith installer: external tools, build, install to ~/Applications, launch.
#   scripts/install.sh            # everything
#   scripts/install.sh --deps     # tools only
#   scripts/install.sh --app      # build + install only
# Uses Homebrew when this user owns it; otherwise installs per-user:
#   ffmpeg/ffprobe/pandoc -> ~/.local/bin, LibreOffice -> ~/Applications.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$HOME/.local/bin"
APPS="$HOME/Applications"
TEAM="${PITH_TEAM:-LKLHZWRD5Y}"
IDENTITY="${PITH_IDENTITY:-D3141EDAD55BE030AC6B09A4714AA3B4D2A44AB1}"
XCODEGEN="${XCODEGEN:-$(command -v xcodegen || echo "$HOME/.local/opt/xcodegen/bin/xcodegen")}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$BIN" "$APPS"

log() { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
have() { [ -x "/opt/homebrew/bin/$1" ] || [ -x "/usr/local/bin/$1" ] || [ -x "$BIN/$1" ]; }

brew_ok() {
  command -v brew >/dev/null 2>&1 || return 1
  [ "$(stat -f %Su "$(brew --prefix)")" = "$(whoami)" ]
}

fetch() { curl -fL --retry 3 --progress-bar -o "$2" "$1"; }

sign_if_needed() {  # Apple Silicon refuses to run unsigned binaries.
  codesign -v "$1" >/dev/null 2>&1 || codesign -f -s - "$1"
}

install_ffmpeg() {
  if have ffmpeg && have ffprobe; then log "ffmpeg already installed"; return; fi
  if brew_ok; then log "brew install ffmpeg"; brew install ffmpeg; return; fi
  [ "$(uname -m)" = arm64 ] || { echo "ffmpeg fallback only supports Apple Silicon; install Homebrew"; return 1; }
  for tool in ffmpeg ffprobe; do
    log "Downloading $tool (arm64 static build)"
    fetch "https://www.osxexperts.net/${tool}9arm.zip" "$TMP/$tool.zip"
    unzip -oq "$TMP/$tool.zip" -d "$TMP/$tool"
    install -m 755 "$(find "$TMP/$tool" -type f -name "$tool" | head -1)" "$BIN/$tool"
    sign_if_needed "$BIN/$tool"
  done
}

install_pandoc() {
  if have pandoc; then log "pandoc already installed"; return; fi
  if brew_ok; then log "brew install pandoc"; brew install pandoc; return; fi
  local arch=arm64; [ "$(uname -m)" = arm64 ] || arch=x86_64
  local url
  url="$(curl -fsSL https://api.github.com/repos/jgm/pandoc/releases/latest \
        | grep -oE "https://[^\"]*-${arch}-macOS\.zip" | head -1)"
  log "Downloading pandoc ($url)"
  fetch "$url" "$TMP/pandoc.zip"
  unzip -oq "$TMP/pandoc.zip" -d "$TMP/pandoc"
  install -m 755 "$(find "$TMP/pandoc" -type f -path '*/bin/pandoc' | head -1)" "$BIN/pandoc"
  sign_if_needed "$BIN/pandoc"
}

install_libreoffice() {
  if [ -d /Applications/LibreOffice.app ] || [ -d "$APPS/LibreOffice.app" ]; then
    log "LibreOffice already installed"; return
  fi
  if brew_ok; then log "brew install --cask libreoffice"; brew install --cask libreoffice; return; fi
  local arch=aarch64; [ "$(uname -m)" = arm64 ] || arch=x86_64
  local base=https://download.documentfoundation.org/libreoffice/stable
  local ver
  ver="$(curl -fsSL "$base/" | grep -oE 'href="[0-9]+(\.[0-9]+)+/"' | grep -oE '[0-9]+(\.[0-9]+)+' | sort -V | tail -1)"
  local dmg="LibreOffice_${ver}_MacOS_${arch}.dmg"
  log "Downloading LibreOffice $ver (~350 MB)"
  fetch "$base/$ver/mac/$arch/$dmg" "$TMP/lo.dmg"
  local mnt="$TMP/mnt"; mkdir -p "$mnt"
  hdiutil attach -nobrowse -quiet -mountpoint "$mnt" "$TMP/lo.dmg"
  ditto "$mnt/LibreOffice.app" "$APPS/LibreOffice.app"
  hdiutil detach -quiet "$mnt"
  xattr -dr com.apple.quarantine "$APPS/LibreOffice.app" 2>/dev/null || true
}

install_xcodegen() {
  [ -x "$XCODEGEN" ] && return
  log "Installing XcodeGen"
  fetch https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip "$TMP/xcodegen.zip"
  mkdir -p "$HOME/.local/opt"; unzip -oq "$TMP/xcodegen.zip" -d "$HOME/.local/opt"
  XCODEGEN="$HOME/.local/opt/xcodegen/bin/xcodegen"
}

build_and_install() {
  install_xcodegen
  cd "$REPO"
  log "Generating project"; "$XCODEGEN" generate >/dev/null
  log "Building Pith"
  xcodebuild -project Pith.xcodeproj -scheme Pith -configuration Debug -derivedDataPath build \
    DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" build \
    > /tmp/pith_build.log 2>&1 || { grep -E "error:" /tmp/pith_build.log | sort -u; exit 1; }
  log "Installing to $APPS/Pith.app"
  pkill -x Pith 2>/dev/null || true; sleep 0.5
  rm -rf "$APPS/Pith.app"; cp -R build/Build/Products/Debug/Pith.app "$APPS/"
  open "$APPS/Pith.app"
}

case "${1:-all}" in
  --deps) install_ffmpeg; install_pandoc; install_libreoffice ;;
  --app)  build_and_install ;;
  *)      install_ffmpeg; install_pandoc; install_libreoffice; build_and_install ;;
esac
log "Done"
