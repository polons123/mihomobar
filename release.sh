#!/bin/bash
# Собирает файлы релиза и подписывает SHA256SUMS.txt (ECDSA P-256) — по ним приложения проверяют обновления.
# Использование: ./release.sh   (перед этим собрать windows\dist\MihomoBar.exe в Windows: windows\build.cmd)
# Ключ подписи: ~/.config/mihomobar/update-signing-key.pem (НЕ терять и не менять: открытый ключ вшит в приложения).
set -e
cd "$(dirname "$0")"
KEY="${UPDATE_SIGNING_KEY:-$HOME/.config/mihomobar/update-signing-key.pem}"
[ -f "$KEY" ] || { echo "нет ключа подписи $KEY" >&2; exit 1; }
VER=$(cat VERSION)
[ -f windows/dist/MihomoBar.exe ] || { echo "нет windows/dist/MihomoBar.exe" >&2; exit 1; }
./build.sh dmg
OUT=release/v$VER; rm -rf "$OUT"; mkdir -p "$OUT"
cp MihomoBar.dmg "$OUT/"
cp windows/dist/MihomoBar.exe "$OUT/MihomoBar.exe"
# Windows: отдельный пакет под каждую архитектуру (exe один и тот же, AnyCPU; ядро и wintun — свои)
find windows/dist -name .DS_Store -delete
for A in x64 arm64; do
  S=$(mktemp -d)/MihomoBar; mkdir -p "$S/core/$A"
  cp windows/dist/MihomoBar.exe "$S/"; cp windows/dist/core/$A/* "$S/core/$A/"; cp windows/dist/core/WINTUN-LICENSE.txt "$S/core/"
  (cd "$(dirname "$S")" && zip -qr "$OLDPWD/$OUT/MihomoBar-windows-$A.zip" MihomoBar)
done
(cd "$OUT" && shasum -a 256 MihomoBar.dmg MihomoBar.exe MihomoBar-windows-x64.zip MihomoBar-windows-arm64.zip > SHA256SUMS.txt \
  && openssl dgst -sha256 -sign "$KEY" -out SHA256SUMS.txt.sig SHA256SUMS.txt)
echo "готово: $OUT"; ls -la "$OUT"
echo "публикация: gh release create v$VER $OUT/* --title v$VER --notes '...'"
