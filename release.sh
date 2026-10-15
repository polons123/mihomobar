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
(cd windows/dist && find . -name .DS_Store -delete && zip -qr "../../$OUT/MihomoBar-windows.zip" .)
(cd "$OUT" && shasum -a 256 MihomoBar.dmg MihomoBar.exe MihomoBar-windows.zip > SHA256SUMS.txt \
  && openssl dgst -sha256 -sign "$KEY" -out SHA256SUMS.txt.sig SHA256SUMS.txt)
echo "готово: $OUT"; ls -la "$OUT"
echo "публикация: gh release create v$VER $OUT/* --title v$VER --notes '...'"
