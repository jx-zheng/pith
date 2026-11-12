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
# Optional: export PITH_TEAM / PITH_IDENTITY for Manual signing.
# PITH_IDENTITY unset: Automatic build, then re-sign with the first Apple
# Development identity in the keychain (SHA-1 hash) when one exists.
TEAM="${PITH_TEAM:-}"
IDENTITY="${PITH_IDENTITY:-}"
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

# First valid "Apple Development..." identity from `security find-identity -v -p codesigning`.
# Sets DEV_HASH to the SHA-1 (never the certificate name). Status 1 when none exists or security fails.
apple_development_hash() {
  local listing line count re
  DEV_HASH=""
  count=0
  listing="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  re='^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40})[[:space:]]+"Apple[[:space:]]Development'
  while IFS= read -r line; do
    if [[ "$line" =~ $re ]]; then
      count=$((count + 1))
      if [ "$count" -eq 1 ]; then
        DEV_HASH="${BASH_REMATCH[1]}"
      fi
    fi
  done <<< "$listing"
  [ -n "$DEV_HASH" ] || return 1
  if [ "$count" -gt 1 ]; then
    log "Apple Development identity found (${DEV_HASH:0:8}...). Set PITH_IDENTITY to override."
  else
    log "Apple Development identity found (${DEV_HASH:0:8}...)"
  fi
}

# Re-sign an Automatic build so Accessibility survives rebuilds.
# Sets APP_TO_INSTALL. Ad-hoc designated requirements pin cdhash; drop them so
# the new requirement is based on the certificate. Failure keeps the original bundle.
resign_for_accessibility() {
  local src="$1" preserve dr staged
  APP_TO_INSTALL="$src"
  if ! apple_development_hash; then
    log "No Apple Development identity found; Accessibility will need re-granting after rebuilds."
    return 0
  fi
  staged="$TMP/resign/Pith.app"
  rm -rf "$TMP/resign"
  mkdir -p "$TMP/resign"
  cp -R "$src" "$staged"
  preserve="identifier,entitlements,requirements,flags"
  dr="$(codesign -dr - "$staged" 2>&1 || true)"
  if [[ "$dr" == *cdhash* ]]; then
    preserve="identifier,entitlements,flags"
  fi
  if ! codesign --force --deep --sign "$DEV_HASH" --preserve-metadata="$preserve" "$staged"; then
    log "Warning: re-sign failed; installing the ad-hoc build. Accessibility will need re-granting after rebuilds."
    return 0
  fi
  if ! codesign --verify --strict "$staged"; then
    log "Warning: re-sign failed; installing the ad-hoc build. Accessibility will need re-granting after rebuilds."
    return 0
  fi
  dr="$(codesign -dr - "$staged" 2>&1 || true)"
  if [[ "$dr" == *cdhash* ]]; then
    log "Signed Pith.app with ${DEV_HASH:0:8}...; verify ok; designated requirement pins cdhash"
  elif [[ "$dr" == *designated* ]]; then
    log "Signed Pith.app with ${DEV_HASH:0:8}...; verify ok; designated requirement is certificate-based"
  else
    log "Signed Pith.app with ${DEV_HASH:0:8}...; verify ok"
  fi
  APP_TO_INSTALL="$staged"
}

build_and_install() {
  install_xcodegen
  cd "$REPO"
  log "Generating project"; "$XCODEGEN" generate >/dev/null
  log "Building Pith"
  SIGN_ARGS=()
  if [ -n "$TEAM" ] && [ -n "$IDENTITY" ]; then
    SIGN_ARGS=(DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY")
  else
    SIGN_ARGS=(CODE_SIGN_STYLE=Automatic)
  fi
  xcodebuild -project Pith.xcodeproj -scheme Pith -configuration Debug -derivedDataPath build \
    "${SIGN_ARGS[@]}" build \
    > /tmp/pith_build.log 2>&1 || { grep -E "error:" /tmp/pith_build.log | sort -u; exit 1; }
  local app="build/Build/Products/Debug/Pith.app"
  # PITH_IDENTITY set: Manual signing above is unchanged (no keychain scan).
  if [ -z "$IDENTITY" ]; then
    resign_for_accessibility "$app"
    app="$APP_TO_INSTALL"
  fi
  log "Installing to $APPS/Pith.app"
  # Wait for the old copy to exit: a new launch hands off to (and quits for) a running one.
  pkill -x Pith 2>/dev/null || true
  for _ in $(seq 1 50); do pgrep -x Pith >/dev/null || break; sleep 0.2; done
  rm -rf "$APPS/Pith.app"; cp -R "$app" "$APPS/"
  open "$APPS/Pith.app"
}

case "${1:-all}" in
  --deps) install_ffmpeg; install_pandoc; install_libreoffice ;;
  --app)  build_and_install ;;
  *)      install_ffmpeg; install_pandoc; install_libreoffice; build_and_install ;;
esac
log "Done"
