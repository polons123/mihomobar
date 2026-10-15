import AppKit
import CryptoKit
import UniformTypeIdentifiers

let managedConfig = "/usr/local/etc/mihomobar/config.yaml"
let ctl = "/usr/local/libexec/mihomo-ctl"
let urlKey = "configURL"
let localKey = "localConfigPath"
let prevConfig = "/usr/local/etc/mihomobar/config.prev.yaml"
let agentPath = NSString(string: "~/Library/LaunchAgents/local.mihomobar.plist").expandingTildeInPath
let expectedHelper = "5"   // версия mihomo-ctl, с которой это приложение совместимо
let modeKey = "configMode"   // "remote" | "local"

struct Controller {
    var base: String
    var secret: String
    var mixedPort: Int = 7890

    // external-controller и secret берём из установленного конфига (файл world-readable).
    static func load() -> Controller? {
        guard let text = try? String(contentsOfFile: managedConfig, encoding: .utf8) else { return nil }
        func value(_ key: String) -> String? {
            for line in text.split(separator: "\n") where line.hasPrefix("\(key):") {
                var v = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                if let h = v.firstIndex(of: "#"), !v.hasPrefix("\"") { v = String(v[..<h]).trimmingCharacters(in: .whitespaces) }
                return v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            return nil
        }
        guard var addr = value("external-controller") else { return nil }
        if addr.hasPrefix(":") { addr = "127.0.0.1" + addr }
        addr = addr.replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1")
        return Controller(base: "http://\(addr)", secret: value("secret") ?? "", mixedPort: Int(value("mixed-port") ?? "") ?? 7890)
    }

    func get(_ path: String, timeout: TimeInterval = 1.5) -> [String: Any]? {
        guard let url = URL(string: base + path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        if !secret.isEmpty { req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { result = obj }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 0.5)
        return result
    }

    /// Суммарный трафик ядра (байты вниз/вверх) — скорость считаем разностью двух замеров.
    func totals() -> (down: Double, up: Double)? {
        guard let c = get("/connections", timeout: 2),
              let d = (c["downloadTotal"] as? NSNumber)?.doubleValue,
              let u = (c["uploadTotal"] as? NSNumber)?.doubleValue else { return nil }
        return (d, u)
    }

    // Идём по цепочке групп (PROXY → узел → ...) до конечного узла.
    func exitNode() -> String? {
        guard let proxies = get("/proxies")?["proxies"] as? [String: [String: Any]] else { return nil }
        var name = proxies["PROXY"] != nil ? "PROXY" : "GLOBAL"
        var seen = Set<String>()
        while let p = proxies[name], let next = p["now"] as? String, !seen.contains(name) {
            seen.insert(name); name = next
        }
        return name
    }
}

struct CtlResult { var code: Int32; var out: String; var err: String }

@discardableResult
func sudoCtl(_ args: [String], stdin: Data? = nil) -> CtlResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    p.arguments = ["-n", ctl] + args
    let o = Pipe(), e = Pipe(), i = Pipe()
    p.standardOutput = o; p.standardError = e
    p.standardInput = stdin == nil ? FileHandle.nullDevice : i
    do { try p.run() } catch { return CtlResult(code: -1, out: "", err: "\(error)") }
    if let stdin { i.fileHandleForWriting.write(stdin); try? i.fileHandleForWriting.close() }
    let out = o.fileHandleForReading.readDataToEndOfFile()
    let err = e.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    func s(_ d: Data) -> String { (String(data: d, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    return CtlResult(code: p.terminationStatus, out: s(out), err: s(err))
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    var running = false
    var exit: String?
    var busy = false
    var note: String?          // результат последнего обновления конфига
    var timer: Timer?
    var desired = false        // пользователь хочет, чтобы прокси работал (для автоперезапуска)
    var blocked = false        // интернет заблокирован после сбоя — до выхода из программы
    var attempts = 0           // подряд неудачных перезапусков
    var recovering = false
    var stableSince: Date?
    var speed: String?
    var lastTotals: (down: Double, up: Double, at: Date)?
    var ipLine: String?
    let maxAttempts = 5
    var helperVersion: String?
    var coreVer: String?
    var helperOutdated = false
    var apiOK = false
    var lastError: String?
    var firstRefresh = true
    var updating = false       // идёт замена приложения: выходим без вопросов, ядро и блокировку не трогаем
    var updateBusy = false
    var availableVersion: String?
    var inFlight: Bool { busy || recovering }

    /// Kill switch: после неудачных перезапусков блокировать интернет (по умолчанию включено).
    var killSwitch: Bool {
        get { UserDefaults.standard.object(forKey: "killSwitch") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "killSwitch") }
    }

    var configURL: String? {
        get { UserDefaults.standard.string(forKey: urlKey) }
        set { UserDefaults.standard.set(newValue, forKey: urlKey) }
    }
    var localPath: String? {
        get { UserDefaults.standard.string(forKey: localKey) }
        set { UserDefaults.standard.set(newValue, forKey: localKey) }
    }
    var useLocal: Bool {
        get { UserDefaults.standard.string(forKey: modeKey) == "local" && localPath != nil }
        set { UserDefaults.standard.set(newValue ? "local" : "remote", forKey: modeKey) }
    }
    var hasPrev: Bool { FileManager.default.fileExists(atPath: prevConfig) }
    var hasConfig: Bool { FileManager.default.fileExists(atPath: managedConfig) }

    func applicationDidFinishLaunching(_ n: Notification) {
        menu.delegate = self
        item.menu = menu
        installEditMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        DispatchQueue.global().async {
            let cv = sudoCtl(["core-version"]).out
            DispatchQueue.main.async { if self.coreVer == nil, !cv.isEmpty { self.coreVer = cv } }
            let v = sudoCtl(["version"])
            let ok = v.code == 0 && v.out == expectedHelper
            DispatchQueue.main.async {
                self.helperVersion = v.code == 0 ? v.out : nil
                self.helperOutdated = !ok
                self.rebuild()
                if !ok { self.offerHelperUpdate() }
            }
            if sudoCtl(["blockstatus"]).out.hasPrefix("blocked") {
                DispatchQueue.main.async { self.blocked = true; self.rebuild(); self.offerUnblock() }
            }
        }
        checkUpdatesOnLaunch()
        // Перед первым стартом — просим ссылку на конфиг.
        if configURL == nil && !useLocal { DispatchQueue.main.async { self.askURL(firstRun: true) } }
    }

    // У приложения без Dock нет главного меню, из-за чего ⌘V/⌘C/⌘A не работают в полях ввода.
    func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    // MARK: состояние

    func refresh() {
        DispatchQueue.global().async {
            let isUp = sudoCtl(["status"]).out.hasPrefix("running")
            let c = isUp ? Controller.load() : nil
            let node = c?.exitNode()
            let live = (c?.get("/version")?["version"] as? String)
            var speed: String?
            var sample: (down: Double, up: Double, at: Date)?
            if let t = c?.totals() { sample = (t.down, t.up, Date()) }
            DispatchQueue.main.async {
                if let sample, let last = self.lastTotals, sample.at.timeIntervalSince(last.at) > 0.5 {
                    let dt = sample.at.timeIntervalSince(last.at)
                    speed = "↓ \(App.rate((sample.down - last.down) / dt))  ↑ \(App.rate((sample.up - last.up) / dt))"
                }
                self.lastTotals = sample
                self.running = isUp; self.exit = node; self.speed = isUp ? speed : nil
                self.apiOK = node != nil
                if let live { self.coreVer = live }   // после обновления из панели показываем актуальную версию
                if self.firstRefresh { self.firstRefresh = false; if isUp { self.desired = true } }   // подхватываем уже работающий mihomo
                self.watchdog()
                self.rebuild()
            }
        }
    }

    static func rate(_ bps: Double) -> String {
        let v = max(bps, 0)
        if v >= 1_048_576 { return String(format: "%.1f МБ/с", v / 1_048_576) }
        if v >= 1024 { return String(format: "%.0f КБ/с", v / 1024) }
        return String(format: "%.0f Б/с", v)
    }

    // MARK: уведомления

    func notify(_ title: String, _ text: String) {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(text))\" with title \"\(esc(title))\""]
        try? p.run()
    }

    // MARK: автоперезапуск и блокировка

    /// Если прокси должен работать, а ядро упало — перезапускаем до maxAttempts раз, затем блокируем интернет.
    func watchdog() {
        guard desired, !busy, !blocked, !recovering else { return }
        if running {
            if stableSince == nil { stableSince = Date() }
            if Date().timeIntervalSince(stableSince!) > 60 { attempts = 0 }
            return
        }
        stableSince = nil
        attempts += 1
        if attempts > maxAttempts { if killSwitch { lockDown() } else { giveUp() }; return }
        recovering = true
        note = "mihomo упал — перезапуск \(attempts)/\(maxAttempts)"
        notify("MihomoBar", "mihomo упал. Перезапуск \(attempts) из \(maxAttempts)")
        let n = attempts
        DispatchQueue.global().async {
            let r = sudoCtl(["start"])
            DispatchQueue.main.async {
                self.recovering = false
                if r.code == 0 { self.note = "Перезапущен после сбоя (попытка \(n))"; self.notify("MihomoBar", "Прокси снова работает") }
                self.refresh()
            }
        }
    }

    /// Kill switch выключен: после исчерпания попыток просто останавливаемся, интернет не блокируем.
    func giveUp() {
        desired = false
        note = "⚠ Прокси не работает: \(maxAttempts) перезапусков не помогли. Kill switch выключен — интернет не заблокирован"
        notify("MihomoBar", "Прокси упал, перезапуски исчерпаны. Kill switch выключен — интернет НЕ заблокирован.")
        rebuild()
    }

    @objc func toggleKillSwitch() { killSwitch.toggle(); rebuild() }

    func lockDown() {
        desired = false; blocked = true; busy = true; rebuild()
        DispatchQueue.global().async {
            sudoCtl(["stop"])
            let r = sudoCtl(["block"])
            // не верим коду возврата — проверяем, что правила реально применились
            let ok = r.code == 0 && sudoCtl(["blockstatus"]).out.hasPrefix("blocked")
            DispatchQueue.main.async {
                self.busy = false
                self.blocked = ok
                if ok {
                    self.note = "Интернет заблокирован после \(self.maxAttempts) неудачных перезапусков"
                    self.notify("MihomoBar — интернет заблокирован", "Прокси не удалось поднять за \(self.maxAttempts) попыток. Блокировка снимется при выходе из программы.")
                } else {
                    let why = r.err.isEmpty ? "блокировка не подтвердилась" : r.err
                    self.lastError = why
                    self.note = "⚠ Прокси не работает, а заблокировать интернет не удалось: \(why)"
                    self.notify("MihomoBar — ВНИМАНИЕ", "Прокси упал, интернет НЕ заблокирован: \(why)")
                }
                self.rebuild()
            }
        }
    }

    /// Снимает блокировку и проверяет результат. Возвращает текст ошибки или nil.
    func unblockNow() -> String? {
        let r = sudoCtl(["unblock"])
        if r.code == 0 && sudoCtl(["blockstatus"]).out.hasPrefix("open") { return nil }
        return r.err.isEmpty ? "блокировка не снялась" : r.err
    }

    func offerUnblock() {
        let a = NSAlert()
        a.messageText = "Интернет заблокирован"
        a.informativeText = "Блокировка осталась после прошлого сбоя. Снять её?"
        a.addButton(withTitle: "Снять блокировку")
        a.addButton(withTitle: "Оставить")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            DispatchQueue.global().async {
                let err = self.unblockNow()
                DispatchQueue.main.async {
                    if let err { self.alert("Не удалось снять блокировку: \(err)\nВ терминале: sudo -n /usr/local/libexec/mihomo-ctl unblock") }
                    else { self.blocked = false; self.attempts = 0 }
                    self.rebuild()
                }
            }
        }
    }

    // MARK: версия хелпера

    func offerHelperUpdate() {
        let a = NSAlert()
        if let hv = helperVersion {
            a.messageText = "Хелпер устарел"
            a.informativeText = "Установленный mihomo-ctl (версия \(hv)) не совместим с приложением (нужна \(expectedHelper)). Без обновления не работают откат и блокировка. Обновить сейчас? Потребуется пароль администратора."
            a.addButton(withTitle: "Обновить")
        } else {
            a.messageText = "Нужна первоначальная установка"
            a.informativeText = "Для управления ядром с правами администратора нужно один раз установить компонент mihomo-ctl и правило sudoers (только на этот файл). Потребуется пароль администратора."
            a.addButton(withTitle: "Установить")
        }
        a.addButton(withTitle: "Позже")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { updateHelper() }
    }

    @objc func updateHelper() {
        // install.sh и mihomo-ctl лежат внутри .app (Resources); для сборки из исходников — рядом с .app
        let inApp = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/install.sh").path
        let beside = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("install.sh").path
        guard let script = [inApp, beside].first(where: { FileManager.default.fileExists(atPath: $0) }) else { alert("Не найден install.sh. Скачайте релиз заново."); return }
        busy = true; rebuild()
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()
            let v = sudoCtl(["version"])
            DispatchQueue.main.async {
                self.busy = false
                self.helperVersion = v.code == 0 ? v.out : nil
                self.helperOutdated = !(v.code == 0 && v.out == expectedHelper)
                if self.helperOutdated { self.alert("Обновить хелпер не удалось. Запустите install.sh из папки с приложением в терминале.") }
                self.rebuild()
            }
        }
    }

    // MARK: проверка IP через зарубежный сервис

    @objc func checkIP() {
        guard running, let c = Controller.load() else { return }
        ipLine = "Проверка IP…"; rebuild()
        DispatchQueue.global().async {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 10
            cfg.connectionProxyDictionary = [
                "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": c.mixedPort,
                "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": c.mixedPort,
            ]
            let session = URLSession(configuration: cfg)
            // Первым — Cloudflare по IP-адресу: DNS не нужен, поэтому DNS-блок-листы не мешают.
            let services: [(String, (Data) -> String?)] = [
                ("https://1.1.1.1/cdn-cgi/trace", { data in
                    let kv = Dictionary(uniqueKeysWithValues: (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").compactMap { l -> (String, String)? in
                        let p = l.split(separator: "=", maxSplits: 1).map(String.init); return p.count == 2 ? (p[0], p[1]) : nil })
                    guard let ip = kv["ip"] else { return nil }
                    return [ip, kv["loc"], kv["colo"]].compactMap { $0 }.joined(separator: " · ")
                }),
                ("https://ipinfo.io/json", { data in
                    guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let ip = o["ip"] as? String else { return nil }
                    return [ip, o["country"] as? String, o["city"] as? String].compactMap { $0 }.joined(separator: " · ")
                }),
                ("https://ipwho.is/", { data in
                    guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let ip = o["ip"] as? String else { return nil }
                    return [ip, o["country"] as? String, o["city"] as? String].compactMap { $0 }.joined(separator: " · ")
                }),
            ]
            var result: String?
            for (u, parse) in services {
                guard let url = URL(string: u) else { continue }
                let sem = DispatchSemaphore(value: 0)
                var line: String?
                session.dataTask(with: url) { data, _, _ in
                    if let data { line = parse(data) }
                    sem.signal()
                }.resume()
                _ = sem.wait(timeout: .now() + 12)
                if let line { result = line; break }
            }
            DispatchQueue.main.async {
                self.ipLine = result.map { "IP выхода: \($0)" } ?? "IP не определён — сервис недоступен через прокси"
                self.rebuild()
            }
        }
    }

    func rebuild() {
        if let b = item.button {
            let name = blocked ? "exclamationmark.shield.fill" : busy ? "hourglass" : (running ? "shield.fill" : "shield")
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: "MihomoBar") {
                img.isTemplate = true; b.image = img; b.title = ""
            } else {
                b.title = busy ? "⏳" : (running ? "●" : "○")
            }
        }

        menu.removeAllItems()
        func info(_ t: String) { let m = NSMenuItem(title: t, action: nil, keyEquivalent: ""); m.isEnabled = false; menu.addItem(m) }
        func act(_ t: String, _ sel: Selector, enabled: Bool = true) {
            let m = NSMenuItem(title: t, action: sel, keyEquivalent: ""); m.target = self; m.isEnabled = enabled; menu.addItem(m)
        }

        info(blocked ? "⛔ Интернет заблокирован" : running ? "Работает" : "Остановлен")
        if blocked { info("Блокировка снимется при выходе из программы") }
        if running { info("Исходящий прокси: \(exit ?? "неизвестно")") }
        if running, let speed { info(speed) }
        if let ipLine { info(ipLine) }
        info(useLocal ? "Конфиг: локальный — \((localPath! as NSString).lastPathComponent)"
                      : "Конфиг: удалённый — \(configURL.flatMap { URL(string: $0)?.host } ?? "ссылка не задана")")
        if let note { info(note) }
        if helperOutdated { act("⚠ Хелпер устарел — обновить…", #selector(updateHelper), enabled: !inFlight) }
        menu.addItem(.separator())

        act(running ? "Выключить прокси" : "Включить прокси", #selector(toggleProxy), enabled: !inFlight && !blocked)
        act("Обновить конфиг и перезапустить", #selector(updateAndRestart), enabled: !inFlight && !blocked)
        act("Откатить к прежнему конфигу", #selector(rollback), enabled: !inFlight && !blocked && hasPrev)
        act("Проверить IP выхода", #selector(checkIP), enabled: running)
        act("Ссылка на конфиг…", #selector(changeURL), enabled: !inFlight)
        act("Использовать локальный конфиг…", #selector(pickLocal), enabled: !inFlight)
        let srcItem = NSMenuItem(title: "Источник конфига", action: nil, keyEquivalent: "")
        let src = NSMenu()
        let host = configURL.flatMap { URL(string: $0)?.host } ?? "не задана"
        let r = NSMenuItem(title: "Удалённый — \(host)", action: #selector(selectRemote), keyEquivalent: "")
        r.target = self; r.state = useLocal ? .off : .on; r.isEnabled = configURL != nil && !inFlight
        let l = NSMenuItem(title: "Локальный — \(localPath.map { ($0 as NSString).lastPathComponent } ?? "не выбран")", action: #selector(selectLocal), keyEquivalent: "")
        l.target = self; l.state = useLocal ? .on : .off; l.isEnabled = localPath != nil && !inFlight
        src.addItem(r); src.addItem(l)
        srcItem.submenu = src
        menu.addItem(srcItem)
        act("Открыть панель", #selector(openPanel), enabled: running)
        let diagItem = NSMenuItem(title: "Диагностика", action: nil, keyEquivalent: "")
        let diag = NSMenu()
        func dinfo(_ t: String) { let m = NSMenuItem(title: t, action: nil, keyEquivalent: ""); m.isEnabled = false; diag.addItem(m) }
        dinfo("Хелпер: " + (helperVersion.map { "v\($0)" + (helperOutdated ? " (устарел, нужна v\(expectedHelper))" : " (ок)") } ?? "недоступен"))
        dinfo("Ядро: " + (coreVer ?? "не установлено — скачается при включении"))
        dinfo("API ядра: " + (running ? (apiOK ? "доступен" : "не отвечает") : "ядро остановлено"))
        dinfo("Версия MihomoBar: " + (Upd.currentVersion ?? "неизвестна"))
        dinfo("Kill switch: " + (killSwitch ? "включён" : "выключен"))
        dinfo("Блокировка интернета: " + (blocked ? "включена" : "выключена"))
        dinfo("Последняя ошибка: " + (lastError.map { String($0.prefix(70)) } ?? "нет"))
        diag.addItem(.separator())
        for (t, sel) in [("Показать лог ядра", #selector(showLog)), ("Показать конфиг в Finder", #selector(showConfig))] {
            let m = NSMenuItem(title: t, action: sel, keyEquivalent: ""); m.target = self; diag.addItem(m)
        }
        diagItem.submenu = diag
        menu.addItem(diagItem)
        menu.addItem(.separator())
        let ks = NSMenuItem(title: "Kill switch: блокировать интернет при сбое прокси", action: #selector(toggleKillSwitch), keyEquivalent: "")
        ks.target = self; ks.state = killSwitch ? .on : .off
        menu.addItem(ks)
        let li = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        li.target = self; li.state = launchAtLogin ? .on : .off
        menu.addItem(li)
        let au = NSMenuItem(title: "Проверять обновления автоматически", action: #selector(toggleAutoUpdate), keyEquivalent: "")
        au.target = self; au.state = autoUpdate ? .on : .off
        menu.addItem(au)
        if let v = availableVersion {
            act("⬆ Доступна версия \(v) — установить…", #selector(checkUpdatesManually), enabled: !updateBusy)
        } else {
            act("Проверить обновления…", #selector(checkUpdatesManually), enabled: !updateBusy)
        }
        menu.addItem(NSMenuItem(title: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: конфиг

    /// Берёт конфиг из выбранного источника (файл или ссылка). Возвращает данные либо причину ошибки.
    func fetchSource() -> (Data?, String?) {
        if useLocal, let path = localPath {
            guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return (nil, "не удалось прочитать \(path)") }
            return (data, nil)
        }
        guard let s = configURL, let url = URL(string: s), url.scheme == "https" || url.scheme == "http" else {
            return (nil, "ссылка на конфиг не задана")
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("clash.meta", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var body: Data?; var failure: String?
        URLSession.shared.dataTask(with: req) { data, resp, error in
            if let error { failure = error.localizedDescription }
            else if let h = resp as? HTTPURLResponse, h.statusCode != 200 { failure = "HTTP \(h.statusCode)" }
            else if let data, !data.isEmpty { body = data }
            else { failure = "пустой ответ" }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 25)
        guard let body else { return (nil, failure ?? "нет ответа") }
        return (body, nil)
    }

    func install(_ data: Data) -> String? {
        let r = sudoCtl(["install-config"], stdin: data)
        return r.code == 0 ? nil : (r.err.isEmpty ? "ошибка установки (код \(r.code))" : r.err)
    }

    /// Получает и ставит конфиг; при любой ошибке возвращает причину — прежний остаётся.
    func updateConfig() -> String? {
        let (data, failure) = fetchSource()
        guard let data else { return failure }
        return install(data)
    }

    static func hhmm() -> String { DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short) }

    @objc func showLog() { NSWorkspace.shared.open(URL(fileURLWithPath: "/var/log/mihomobar.log")) }
    @objc func showConfig() { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: managedConfig)]) }

    // MARK: откат

    @objc func rollback() {
        guard !inFlight else { return }
        busy = true; rebuild()
        DispatchQueue.global().async {
            var r = sudoCtl(["rollback"])
            let wasRunning = sudoCtl(["status"]).out.hasPrefix("running")
            if r.code == 0 && wasRunning { r = sudoCtl(["start"]) }
            DispatchQueue.main.async {
                self.busy = false
                if r.code != 0 { self.alert(r.err.isEmpty ? "Откат не удался (код \(r.code))" : r.err) }
                else { self.note = "Выполнен откат к прежнему конфигу " + App.hhmm() }
                self.refresh()
            }
        }
    }

    // MARK: автозапуск при входе

    var launchAtLogin: Bool { FileManager.default.fileExists(atPath: agentPath) }

    @objc func toggleLaunchAtLogin() {
        if launchAtLogin { try? FileManager.default.removeItem(atPath: agentPath); rebuild(); return }
        guard let exe = Bundle.main.executablePath else { return }
        let plist: [String: Any] = ["Label": "local.mihomobar", "ProgramArguments": [exe], "RunAtLoad": true, "ProcessType": "Interactive"]
        try? FileManager.default.createDirectory(atPath: (agentPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        (plist as NSDictionary).write(toFile: agentPath, atomically: true)
        rebuild()
    }

    // MARK: выход

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if updating { return .terminateNow }   // обновление: ядро и блокировку оставляем как есть
        // Сначала спрашиваем — состояние (desired, блокировка) меняем только после подтверждения выхода.
        let up = sudoCtl(["status"]).out.hasPrefix("running")
        var stopCore = false
        if up {
            let a = NSAlert()
            a.messageText = "Прокси ещё работает"
            a.informativeText = "Остановить mihomo перед выходом? Иначе TUN продолжит работать без значка в строке меню."
            a.addButton(withTitle: "Остановить и выйти")
            a.addButton(withTitle: "Оставить работать")
            a.addButton(withTitle: "Отмена")
            NSApp.activate(ignoringOtherApps: true)
            switch a.runModal() {
            case .alertFirstButtonReturn: stopCore = true
            case .alertSecondButtonReturn: break
            default: return .terminateCancel
            }
        }
        desired = false
        if stopCore { sudoCtl(["stop"]) }
        if blocked {
            if let err = unblockNow() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("sudo -n /usr/local/libexec/mihomo-ctl unblock", forType: .string)
                alert("Не удалось снять блокировку: \(err)\nКоманда для терминала скопирована в буфер:\nsudo -n /usr/local/libexec/mihomo-ctl unblock")
            }
            blocked = false
        }
        return .terminateNow
    }

    // MARK: установка ядра

    func httpData(_ url: String, timeout: TimeInterval) -> (Data?, String?) {
        guard let u = URL(string: url) else { return (nil, "плохой адрес") }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.setValue("MihomoBar", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var body: Data?; var failure: String?
        URLSession.shared.dataTask(with: req) { data, resp, error in
            if let error { failure = error.localizedDescription }
            else if let h = resp as? HTTPURLResponse, h.statusCode != 200 { failure = "HTTP \(h.statusCode)" }
            else { body = data }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 5)
        return (body, failure ?? (body == nil ? "нет ответа" : nil))
    }

    func gunzip(_ data: Data) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        p.arguments = ["-c"]
        let i = Pipe(), o = Pipe()
        p.standardInput = i; p.standardOutput = o; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        DispatchQueue.global().async { i.fileHandleForWriting.write(data); try? i.fileHandleForWriting.close() }
        let out = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 && !out.isEmpty ? out : nil
    }

    /// Если ядра нет — скачивает последний релиз mihomo с GitHub (mihomo-darwin-<arch>-vX.Y.Z.gz), проверяет SHA-256
    /// из метаданных GitHub и отдаёт хелперу. Установленное (в т.ч. обновлённое из панели) ядро хелпер не затирает.
    func ensureCore() -> String? {
        if !sudoCtl(["core-version"]).out.isEmpty { return nil }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        let (relData, relErr) = httpData("https://api.github.com/repos/MetaCubeX/mihomo/releases/latest", timeout: 20)
        guard let relData, let rel = try? JSONSerialization.jsonObject(with: relData) as? [String: Any],
              let assets = rel["assets"] as? [[String: Any]] else { return "не удалось получить список релизов: \(relErr ?? "?")" }
        let rx = try! NSRegularExpression(pattern: "^mihomo-darwin-\(arch)-v\\d+\\.\\d+\\.\\d+\\.gz$")
        guard let asset = assets.first(where: { a in
            let n = a["name"] as? String ?? ""
            return rx.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) != nil
        }), let url = asset["browser_download_url"] as? String else { return "в релизе нет mihomo-darwin-\(arch)" }
        let (gz, gzErr) = httpData(url, timeout: 180)
        guard let gz else { return "не удалось скачать ядро: \(gzErr ?? "?")" }
        if let digest = asset["digest"] as? String, digest.hasPrefix("sha256:") {
            let sum = SHA256.hash(data: gz).map { String(format: "%02x", $0) }.joined()
            if sum != digest.dropFirst(7).lowercased() { return "контрольная сумма скачанного ядра не совпала" }
        }
        guard let bin = gunzip(gz) else { return "не удалось распаковать ядро" }
        let r = sudoCtl(["install-core"], stdin: bin)
        return r.code == 0 ? nil : (r.err.isEmpty ? "установка ядра не удалась (код \(r.code))" : r.err)
    }

    /// Обновляет конфиг (если не вышло — остаётся прежний) и запускает mihomo.
    func startFlow() {
        guard !inFlight else { return }
        busy = true; rebuild()
        DispatchQueue.global().async {
            if let coreErr = self.ensureCore() {
                DispatchQueue.main.async {
                    self.busy = false; self.desired = false
                    self.note = "Ядро не установлено: \(coreErr)"
                    self.notify("MihomoBar", "Не удалось установить ядро mihomo")
                    self.alert("Не удалось установить ядро mihomo: \(coreErr)")
                    self.refresh()
                }
                return
            }
            let cv = sudoCtl(["core-version"]).out
            if !cv.isEmpty { DispatchQueue.main.async { self.coreVer = cv } }
            let before = FileManager.default.contents(atPath: managedConfig)
            let failure = self.updateConfig()
            let changed = failure == nil && before != FileManager.default.contents(atPath: managedConfig)
            let usable = failure == nil || self.hasConfig
            var error: String?
            var rolledBack = false
            if usable {
                var r = sudoCtl(["start"])
                // новый конфиг прошёл проверку, но ядро не поднялось — возвращаем прежний
                if r.code != 0 && changed && self.hasPrev && sudoCtl(["rollback"]).code == 0 {
                    r = sudoCtl(["start"]); rolledBack = r.code == 0
                }
                if r.code != 0 { error = r.err.isEmpty ? "не удалось запустить (код \(r.code))" : r.err }
            }
            DispatchQueue.main.async {
                self.busy = false
                self.desired = usable && error == nil
                self.attempts = 0; self.stableSince = nil; self.ipLine = nil
                if let error { self.notify("MihomoBar", "Не удалось запустить: \(error)") }
                if rolledBack { self.note = "Новый конфиг не запустился — автоматически восстановлен прежний"; self.notify("MihomoBar", "Новый конфиг не запустился, восстановлен прежний") }
                else if let failure { self.note = self.hasConfig ? "Конфиг не обновлён (\(failure)) — используется прежний" : nil }
                else { self.note = (self.useLocal ? "Локальный конфиг загружен " : "Конфиг обновлён ") + App.hhmm() }
                if !usable { self.alert("Не удалось получить конфиг: \(failure ?? "")\nЗаданной ссылки: \(self.configURL ?? "—")") }
                else if let error { self.alert(error) }
                self.refresh()
            }
        }
    }

    // MARK: действия

    @objc func toggleProxy() {
        guard !inFlight else { return }
        if running {
            desired = false
            busy = true; rebuild()
            DispatchQueue.global().async {
                let r = sudoCtl(["stop"])
                DispatchQueue.main.async {
                    self.busy = false
                    if r.code != 0 { self.alert(r.err.isEmpty ? "Ошибка остановки. Запустите install.sh." : r.err) }
                    self.refresh()
                }
            }
        } else {
            if configURL == nil && !useLocal { askURL(firstRun: true); return }
            startFlow()
        }
    }

    @objc func updateAndRestart() {
        guard !inFlight else { return }
        if configURL == nil && !useLocal { askURL(firstRun: true); return }
        startFlow()
    }

    @objc func changeURL() { askURL(firstRun: false) }

    @objc func pickLocal() {
        guard !inFlight else { return }
        let p = NSOpenPanel()
        p.title = "Выберите локальный конфиг mihomo"
        p.allowedContentTypes = [.yaml, .data].compactMap { $0 }
        p.allowsOtherFileTypes = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let u = p.url else { return }
        localPath = u.path
        useLocal = true
        startFlow()
    }

    @objc func selectRemote() { guard !inFlight else { return }; useLocal = false; startFlow() }
    @objc func selectLocal() { guard !inFlight else { return }; useLocal = true; startFlow() }

    @objc func openPanel() {
        guard let c = Controller.load(), let u = URL(string: c.base + "/ui") else { return }
        NSWorkspace.shared.open(u)
    }

    func askURL(firstRun: Bool) {
        guard !inFlight else { return }
        let a = NSAlert()
        a.messageText = firstRun ? "Ссылка на конфиг" : "Изменить ссылку на конфиг"
        a.informativeText = "Конфиг mihomo (YAML) будет скачиваться по этой ссылке при каждом запуске."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "https://…"
        field.stringValue = configURL ?? ""
        a.accessoryView = field
        a.addButton(withTitle: firstRun ? "Скачать и запустить" : "Сохранить и перезапустить")
        a.addButton(withTitle: "Отмена")
        a.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let s = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: s), u.scheme == "https" || u.scheme == "http" else { alert("Нужна ссылка http(s)://…"); return }
        configURL = s
        useLocal = false
        startFlow()
    }

    func alert(_ text: String) {
        lastError = text
        let a = NSAlert(); a.messageText = "MihomoBar"; a.informativeText = text
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }
}

// MARK: - Обновления

/// Проверка и установка обновлений из GitHub Releases.
/// Цепочка доверия: подпись ECDSA P-256 файла SHA256SUMS.txt (открытый ключ вшит) → SHA-256 образа MihomoBar.dmg →
/// проверка распакованного .app (bundle id, версия, подпись кода). Настройки лежат вне .app и при замене не затрагиваются.
enum Upd {
    /// Открытый ключ P-256 (формат 04‖X‖Y, hex). Закрытый ключ — только у автора релизов.
    static let publicKeyHex = "0470d7739dcbb9a2a376e4d3e64e5a807a4ad58148dbb0bad321fcd0e83bd829fd755c98a971e0a16f0bb10b9314d35e535df5965c9511531289064cc6fbcf181c"
    static let repo = "polons123/mihomobar"
    static let maxMeta = 1_000_000
    static let maxPackage = 50_000_000

    static var env: [String: String] { ProcessInfo.processInfo.environment }
    /// Версия запущенного приложения; MIHOMOBAR_UPDATE_VERSION подменяет её для проверки.
    static var currentVersion: String? {
        env["MIHOMOBAR_UPDATE_VERSION"] ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    static func parseVersion(_ s: String) -> [Int]? {
        let t = s.hasPrefix("v") ? String(s.dropFirst()) : s
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let nums = parts.compactMap { Int($0) }
        return nums.count == 3 ? nums : nil
    }
    static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parseVersion(a), let y = parseVersion(b) else { return false }
        return x != y && !x.lexicographicallyPrecedes(y)
    }
    static func parseSums(_ text: String) -> [String: String] {
        var r: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let p = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard p.count == 2, p[0].count == 64, p[0].allSatisfy(\.isHexDigit) else { continue }
            var name = p[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            r[name] = p[0].lowercased()
        }
        return r
    }
    static func hexData(_ s: String) -> Data? {
        guard s.count % 2 == 0 else { return nil }
        var d = Data(); var i = s.startIndex
        while i < s.endIndex {
            let n = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<n], radix: 16) else { return nil }
            d.append(b); i = n
        }
        return d
    }
    /// Подпись — DER (как выдаёт `openssl dgst -sha256 -sign`).
    static func verify(message: Data, signature: Data, keyHex: String = publicKeyHex) -> Bool {
        guard let raw = hexData(keyHex), let key = try? P256.Signing.PublicKey(x963Representation: raw),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return key.isValidSignature(sig, for: message)
    }
    static func sha256(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let c = try? h.read(upToCount: 1 << 20), !c.isEmpty { hasher.update(data: c) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension App {
    var autoUpdate: Bool {
        get { UserDefaults.standard.object(forKey: "updateAutoCheck") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "updateAutoCheck") }
    }

    @objc func toggleAutoUpdate() { autoUpdate.toggle(); rebuild() }
    @objc func checkUpdatesManually() { runUpdateCheck(manual: true) }

    /// Фоновая проверка при запуске: не чаще раза в сутки, без сообщений, если обновлений нет или ошибка.
    func checkUpdatesOnLaunch() {
        guard autoUpdate, Upd.currentVersion != nil else { return }
        let last = UserDefaults.standard.double(forKey: "updateLastCheck")
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        runUpdateCheck(manual: false)
    }

    func runUpdateCheck(manual: Bool) {
        guard !updateBusy else { return }
        guard let current = Upd.currentVersion, Upd.parseVersion(current) != nil else {
            if manual { alert("Не удалось определить версию приложения (запуск не из пакета .app).") }
            return
        }
        updateBusy = true; rebuild()
        DispatchQueue.global().async {
            let api = Upd.env["MIHOMOBAR_UPDATE_API"] ?? "https://api.github.com/repos/\(Upd.repo)/releases/latest"
            let (data, err) = self.httpData(api, timeout: 15)
            var release: (version: String, notes: String, page: String)?
            if let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let tag = obj["tag_name"] as? String, Upd.parseVersion(tag) != nil,
               (obj["draft"] as? Bool) != true, (obj["prerelease"] as? Bool) != true {
                release = (tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, (obj["body"] as? String) ?? "",
                           (obj["html_url"] as? String) ?? "https://github.com/\(Upd.repo)/releases")
            }
            DispatchQueue.main.async {
                self.updateBusy = false
                if let release {
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "updateLastCheck")
                    if Upd.isNewer(release.version, than: current) {
                        self.availableVersion = release.version
                        self.rebuild()
                        if manual || UserDefaults.standard.string(forKey: "updateSkipped") != release.version {
                            self.offerUpdate(release, current: current)
                        }
                    } else {
                        self.availableVersion = nil; self.rebuild()
                        if manual { self.alert("У вас последняя версия: MihomoBar \(current).") }
                    }
                } else {
                    self.rebuild()
                    let why = err ?? "не удалось разобрать ответ сервера обновлений"
                    self.lastError = "проверка обновлений: \(why)"
                    if manual { self.alert("Не удалось проверить обновления: \(why)") }
                }
            }
        }
    }

    /// Автоустановка возможна, если приложение запущено из .app вне «переноса» Gatekeeper и рядом можно писать.
    var updateBlocker: String? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else { return "приложение запущено не из пакета .app" }
        if url.path.contains("/AppTranslocation/") { return "приложение запущено прямо из загрузок или образа: переместите его в «Программы» и запустите оттуда" }
        if !FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) { return "нет прав на запись в папку \(url.deletingLastPathComponent().path)" }
        return nil
    }

    func offerUpdate(_ r: (version: String, notes: String, page: String), current: String) {
        let blocker = updateBlocker
        let a = NSAlert()
        a.messageText = "Доступна версия \(r.version)"
        var info = "Установлена версия \(current)."
        let notes = r.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { info += "\n\n" + String(notes.prefix(700)) }
        if let blocker { info += "\n\nАвтоустановка недоступна: \(blocker)." }
        else { info += "\n\nНастройки сохранятся. Прокси продолжит работать, приложение перезапустится." }
        a.informativeText = info
        a.addButton(withTitle: blocker == nil ? "Установить и перезапустить" : "Открыть страницу загрузки")
        a.addButton(withTitle: "Позже")
        a.addButton(withTitle: "Пропустить эту версию")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn:
            if blocker == nil { installUpdate(r.version) }
            else if let u = URL(string: r.page), u.scheme == "https" { NSWorkspace.shared.open(u) }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(r.version, forKey: "updateSkipped")
        default: break
        }
    }

    func installUpdate(_ version: String) {
        updateBusy = true; busy = true; note = "Загрузка обновления \(version)…"; rebuild()
        DispatchQueue.global().async {
            let err = self.downloadAndApplyUpdate(version)
            DispatchQueue.main.async {
                if let err {
                    self.updateBusy = false; self.busy = false; self.note = nil
                    self.lastError = "обновление: \(err)"
                    self.alert("Не удалось установить обновление: \(err)\n\nУстановленная версия не изменена.")
                    self.rebuild()
                } else {
                    self.updating = true
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// Скачивает, проверяет и готовит замену .app; возвращает текст ошибки или nil (тогда запущен скрипт замены).
    func downloadAndApplyUpdate(_ version: String) -> String? {
        let base = Upd.env["MIHOMOBAR_UPDATE_BASE"] ?? "https://github.com/\(Upd.repo)/releases/download"
        let name = "MihomoBar.dmg"
        func url(_ n: String) -> String { "\(base)/v\(version)/\(n)" }
        let (sums, e1) = httpData(url("SHA256SUMS.txt"), timeout: 30)
        let (sig, e2) = httpData(url("SHA256SUMS.txt.sig"), timeout: 30)
        guard let sums, let sig, sums.count < Upd.maxMeta else { return "не удалось загрузить список контрольных сумм (\(e1 ?? e2 ?? "?"))" }
        let key = Upd.env["MIHOMOBAR_UPDATE_PUBKEY"] ?? Upd.publicKeyHex
        guard Upd.verify(message: sums, signature: sig, keyHex: key) else {
            return "подпись списка контрольных сумм не прошла проверку: файлы релиза не заслуживают доверия"
        }
        guard let expected = Upd.parseSums(String(decoding: sums, as: UTF8.self))[name] else { return "в списке контрольных сумм нет файла \(name)" }

        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("mihomobar-update-\(version)", isDirectory: true)
        try? fm.removeItem(at: stage)
        do { try fm.createDirectory(at: stage, withIntermediateDirectories: true) } catch { return "не удалось создать папку: \(error.localizedDescription)" }
        let (dmgData, e3) = httpData(url(name), timeout: 120)
        guard let dmgData, dmgData.count <= Upd.maxPackage else { return "не удалось загрузить \(name) (\(e3 ?? "слишком большой"))" }
        let dmg = stage.appendingPathComponent(name)
        do { try dmgData.write(to: dmg) } catch { return "не удалось сохранить файл: \(error.localizedDescription)" }
        guard Upd.sha256(dmg) == expected else { return "контрольная сумма загруженного файла не совпала" }

        // Монтируем образ только для чтения, копируем .app, отключаем.
        let mnt = stage.appendingPathComponent("mnt", isDirectory: true)
        try? fm.createDirectory(at: mnt, withIntermediateDirectories: true)
        func run(_ exe: String, _ args: [String]) -> Int32 {
            let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return -1 }
            p.waitUntilExit(); return p.terminationStatus
        }
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-mountpoint", mnt.path, dmg.path]) == 0 else { return "не удалось открыть образ" }
        let newApp = stage.appendingPathComponent("MihomoBar.app")
        let copied = run("/usr/bin/ditto", [mnt.appendingPathComponent("MihomoBar.app").path, newApp.path])
        _ = run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mnt.path])
        guard copied == 0 else { return "в образе нет MihomoBar.app" }
        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == version else { return "в образе не тот пакет (идентификатор или версия не совпали)" }
        guard run("/usr/bin/codesign", ["--verify", "--strict", "--deep", newApp.path]) == 0 else { return "подпись пакета в образе нарушена" }

        let target = Bundle.main.bundleURL
        let backup = fm.temporaryDirectory.appendingPathComponent("mihomobar-previous", isDirectory: true).appendingPathComponent("MihomoBar.app")
        let script = stage.appendingPathComponent("replace.sh")
        do { try Upd.replaceScript.write(to: script, atomically: true, encoding: .utf8) } catch { return "не удалось подготовить замену" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, target.path, backup.path]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "не удалось запустить замену: \(error.localizedDescription)" }
        return nil
    }
}

extension Upd {
    /// Ждёт выхода приложения, меняет пакет (прежний сохраняется), снимает карантин и запускает новую версию; при ошибке возвращает прежнюю.
    static let replaceScript = """
    #!/bin/sh
    PID="$1"; NEW="$2"; TARGET="$3"; BACKUP="$4"
    LOG="$HOME/Library/Logs/MihomoBar-update.log"
    say() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
    n=0
    while kill -0 "$PID" 2>/dev/null; do
      n=$((n+1)); [ "$n" -gt 150 ] && { say "приложение не закрылось, обновление отменено"; exit 1; }
      sleep 0.2
    done
    mkdir -p "$(dirname "$BACKUP")"; rm -rf "$BACKUP"
    if ! mv "$TARGET" "$BACKUP"; then say "не удалось убрать прежнюю версию"; open "$TARGET"; exit 1; fi
    if ! mv "$NEW" "$TARGET"; then
      say "не удалось поставить новую версию, возвращаю прежнюю"
      rm -rf "$TARGET"; mv "$BACKUP" "$TARGET"; open "$TARGET"; exit 1
    fi
    xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
    say "обновлено: $TARGET"
    open "$TARGET"
    """
}

// Скрытая проверка установки ядра без GUI: MihomoBar --ensure-core
if CommandLine.arguments.contains("--ensure-core") {
    let e = App().ensureCore()
    print(e ?? "ok")
    exit(e == nil ? 0 : 1)
}

// Скрытая проверка обновления без GUI: MihomoBar --apply-update <версия> (скачать, проверить, заменить себя и перезапустить)
if let i = CommandLine.arguments.firstIndex(of: "--apply-update"), i + 1 < CommandLine.arguments.count {
    let e = App().downloadAndApplyUpdate(CommandLine.arguments[i + 1])
    print(e ?? "ok")
    exit(e == nil ? 0 : 1)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
