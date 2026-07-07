#!/usr/bin/env bash
# Instala SDLMAME (Apple Silicon) + SDL3 en arcade-ai/vendor/
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" ]]; then
  echo "Este script instala el build arm64. En Intel usa: brew install mame"
  exit 1
fi

mkdir -p vendor

echo "=== 1/3 SDL3 3.4.8 (requerido por MAME 0.288+) ==="
if [[ ! -d vendor/Frameworks/SDL3.framework ]]; then
  curl -fL --retry 3 -o vendor/SDL3-3.4.8.dmg \
    "https://github.com/libsdl-org/SDL/releases/download/release-3.4.8/SDL3-3.4.8.dmg"
  hdiutil attach vendor/SDL3-3.4.8.dmg -nobrowse -quiet
  mkdir -p vendor/Frameworks
  cp -R /Volumes/SDL3/SDL3.xcframework/macos-arm64_x86_64/SDL3.framework vendor/Frameworks/
  hdiutil detach /Volumes/SDL3 -quiet
  echo "  ✅ SDL3 instalado en vendor/Frameworks/"
else
  echo "  ✅ SDL3 ya presente"
fi

echo ""
echo "=== 2/3 SDLMAME 0.288 (Apple Silicon) ==="
if [[ ! -x vendor/mame/mame0288-arm64/mame ]]; then
  curl -fL --retry 3 -o vendor/mame0288-arm64.zip \
    "https://sdlmame.lngn.net/stable/mame0288-arm64.zip"
  unzip -q -o vendor/mame0288-arm64.zip -d vendor/mame
  echo "  ✅ MAME extraído en vendor/mame/mame0288-arm64/"
else
  echo "  ✅ MAME ya presente"
fi

echo ""
echo "=== 3/3 Verificación ==="
chmod +x bin/mame
./bin/mame -version

echo ""
echo "Listo. Usa:"
echo "  ./bin/mame -listfull | head"
echo "  ./bin/mame pacman -rompath roms   # con ROM legal en roms/"
echo ""
echo "Nota: el binario no está firmado por Apple. Si macOS lo bloquea,"
echo "  clic derecho → Abrir en vendor/mame/mame0288-arm64/mame"
