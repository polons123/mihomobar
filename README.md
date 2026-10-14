# MihomoBar

Лёгкий значок в строке меню (macOS) и в трее (Windows) для [mihomo](https://github.com/MetaCubeX/mihomo) (Clash Meta) с обязательным TUN.

- Конфиг по ссылке-подписке или локальный файл; обновляется при каждом запуске, при ошибке используется прежний.
- «Обновить конфиг и перезапустить», откат к прежнему конфигу, проверка IP выхода, скорость, выбор исходящего прокси.
- Автоперезапуск (5 попыток), затем аварийная блокировка интернета до ручного выхода из программы.
- Ядро ставится само (GitHub Releases, проверка SHA-256) и обновляется из веб-панели штатно: файл всегда называется `mihomo`.

## macOS
Нужен Xcode Command Line Tools (`swiftc`).
```
./build.sh      # собирает MihomoBar.app
./install.sh    # один раз: root-хелпер + sudoers (запросит пароль администратора)
open MihomoBar.app
```
Хелпер `mihomo-ctl` ставится в `/usr/local/libexec`, sudoers разрешает без пароля только его. Блокировка — `pf` anchor `com.apple/mihomobar`.
Аварийно: `sudo /usr/local/libexec/mihomo-ctl unblock`.

## Windows
См. [windows/README.md](windows/README.md). Сборка — `windows\build.cmd` (штатный .NET Framework 4, SDK не нужен).

## Готовые сборки
Скачайте из Releases: `MihomoBar-windows.zip` или `MihomoBar-macos.zip`.
- **Windows:** `MihomoBar.exe` не подписан сертификатом издателя — SmartScreen покажет предупреждение: «Подробнее» → «Выполнить в любом случае». Перед распаковкой можно снять пометку: свойства zip → «Разблокировать».
- **macOS:** `.app` подписан только ad-hoc; после скачивания выполните `xattr -cr MihomoBar.app`, затем `./install.sh` из той же папки.

## Известные ограничения
- Аварийная блокировка на macOS (`pf` anchor `com.apple/mihomobar`) вживую протестирована ограниченно — держите под рукой `sudo /usr/local/libexec/mihomo-ctl unblock`.
- Клики по меню и уведомления в автотестах не проверялись; на реальном x64-ПК с Windows сборка не запускалась (проверено на ARM64 в виртуальной машине).

## Лицензия
GPL-3.0. Использует mihomo (GPL-3.0) и Wintun (см. `windows/dist/core/WINTUN-LICENSE.txt` в релизных сборках).
