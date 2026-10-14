#!/bin/bash
# Одноразовая установка: хелпер + sudoers. Ядро mihomo приложение скачивает с GitHub само (install-core).
# Если нет терминала — сам запросит пароль администратора через системное окно macOS.
set -e
cd "$(dirname "$0")"
DIR="$PWD"
if [ "$(id -u)" != 0 ]; then
  exec osascript -e "do shell script \"/bin/bash '$DIR/install.sh' $(whoami) '$HOME'\" with administrator privileges"
fi
U="$1"; H="$2"
mkdir -p /usr/local/libexec
install -o root -g wheel -m 755 "$DIR/mihomo-ctl" /usr/local/libexec/mihomo-ctl
echo "$U ALL=(root) NOPASSWD: /usr/local/libexec/mihomo-ctl" > /etc/sudoers.d/mihomobar
chmod 440 /etc/sudoers.d/mihomobar
visudo -cf /etc/sudoers.d/mihomobar
echo OK
