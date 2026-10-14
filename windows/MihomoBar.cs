// MihomoBar для Windows: значок в трее для mihomo с обязательным TUN.
// Собирается штатным csc.exe из .NET Framework 4 (C# 5), отдельный рантайм не нужен.
// Запускается с правами администратора (манифест) — отдельный root-хелпер, как на macOS, не требуется.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

namespace MihomoBar
{
    static class P
    {
        public static readonly string AppDir = AppDomain.CurrentDomain.BaseDirectory;
        public static readonly string DataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "MihomoBar");
        public static readonly string Cfg = Path.Combine(DataDir, "config.yaml");
        public static readonly string Prev = Path.Combine(DataDir, "config.prev.yaml");
        public static readonly string Settings = Path.Combine(DataDir, "settings.json");
        public static readonly string Log = Path.Combine(DataDir, "mihomo.log");
        public const string FwRule = "MihomoBar-Block";
        public const string TaskName = "MihomoBar";

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool IsWow64Process2(IntPtr hProcess, out ushort processMachine, out ushort nativeMachine);

        // Архитектура самой машины, а не процесса: AnyCPU-приложение на ARM64 Windows может работать под эмуляцией x64,
        // и переменные окружения тогда говорят AMD64.
        public static string Arch()
        {
            try
            {
                ushort proc, native;
                if (IsWow64Process2(Process.GetCurrentProcess().Handle, out proc, out native))
                    return native == 0xAA64 ? "arm64" : "x64";
            }
            catch { }       // старые версии Windows без IsWow64Process2
            string a = Environment.GetEnvironmentVariable("PROCESSOR_ARCHITEW6432");
            if (string.IsNullOrEmpty(a)) a = Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE");
            return string.Equals(a, "ARM64", StringComparison.OrdinalIgnoreCase) ? "arm64" : "x64";
        }
        // Рабочее ядро: отдельная папка в ProgramData (писать может только администратор), имя всегда mihomo.exe —
        // так встроенное обновление из панели (POST /upgrade) подменяет файл на месте, а процесс виден по имени «mihomo».
        public static string CoreDir() { return Path.Combine(DataDir, "core"); }
        public static string CoreExe() { return Path.Combine(CoreDir(), "mihomo.exe"); }
        // Копия из пакета — только «семя» для первой установки; рабочее ядро она не затирает, пока не новее.
        public static string SeedDir() { return Path.Combine(AppDir, "core", Arch()); }
    }

    static class Sys
    {
        // Запуск скрытого процесса и ожидание; возвращает код выхода, stdout+stderr — в output.
        public static int Run(string file, string args, out string output, int timeoutMs)
        {
            var psi = new ProcessStartInfo(file, args);
            psi.UseShellExecute = false; psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = Encoding.GetEncoding(CultureInfoOem());
            psi.StandardErrorEncoding = psi.StandardOutputEncoding;
            var sb = new StringBuilder();
            try
            {
                using (var p = Process.Start(psi))
                {
                    p.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null) lock (sb) sb.AppendLine(e.Data); };
                    p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null) lock (sb) sb.AppendLine(e.Data); };
                    p.BeginOutputReadLine(); p.BeginErrorReadLine();
                    if (!p.WaitForExit(timeoutMs)) { try { p.Kill(); } catch { } output = sb.ToString(); return -2; }
                    p.WaitForExit();
                    output = sb.ToString();
                    return p.ExitCode;
                }
            }
            catch (Exception ex) { output = ex.Message; return -1; }
        }
        static int CultureInfoOem() { return System.Globalization.CultureInfo.CurrentCulture.TextInfo.OEMCodePage; }

        public static string LastLine(string s)
        {
            var lines = (s ?? "").Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).ToArray();
            return lines.Length == 0 ? "" : lines[lines.Length - 1];
        }
    }

    // ---- клиент REST API ядра ----
    class Controller
    {
        public string Base, Secret; public int MixedPort = 7890;
        static readonly JavaScriptSerializer Js = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };

        public static Controller Load()
        {
            string text;
            try { text = File.ReadAllText(P.Cfg); } catch { return null; }
            Func<string, string> val = delegate(string key)
            {
                foreach (var raw in text.Split('\n'))
                {
                    var line = raw.TrimEnd('\r');
                    if (!line.StartsWith(key + ":")) continue;
                    var v = line.Substring(key.Length + 1).Trim();
                    int h = v.IndexOf('#');
                    if (h >= 0 && !v.StartsWith("\"")) v = v.Substring(0, h).Trim();
                    return v.Trim('"', '\'');
                }
                return null;
            };
            var addr = val("external-controller");
            if (addr == null) return null;
            if (addr.StartsWith(":")) addr = "127.0.0.1" + addr;
            addr = addr.Replace("0.0.0.0", "127.0.0.1");
            var c = new Controller { Base = "http://" + addr, Secret = val("secret") ?? "" };
            int mp; if (int.TryParse(val("mixed-port") ?? "", out mp)) c.MixedPort = mp;
            return c;
        }

        public Dictionary<string, object> Get(string path, int timeoutMs)
        {
            try
            {
                var req = (HttpWebRequest)WebRequest.Create(Base + path);
                req.Timeout = timeoutMs; req.ReadWriteTimeout = timeoutMs; req.Proxy = null;
                if (Secret.Length > 0) req.Headers["Authorization"] = "Bearer " + Secret;
                using (var resp = req.GetResponse())
                using (var rd = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
                    return Js.DeserializeObject(rd.ReadToEnd()) as Dictionary<string, object>;
            }
            catch { return null; }
        }

        // Цепочка групп PROXY → узел → ... до конечного узла.
        public string ExitNode()
        {
            var root = Get("/proxies", 1500);
            if (root == null) return null;
            var proxies = root.ContainsKey("proxies") ? root["proxies"] as Dictionary<string, object> : null;
            if (proxies == null) return null;
            string name = proxies.ContainsKey("PROXY") ? "PROXY" : "GLOBAL";
            var seen = new HashSet<string>();
            while (proxies.ContainsKey(name) && !seen.Contains(name))
            {
                var p = proxies[name] as Dictionary<string, object>;
                if (p == null || !p.ContainsKey("now")) break;
                seen.Add(name); name = Convert.ToString(p["now"]);
            }
            return name;
        }

        public string Version()
        {
            var v = Get("/version", 1500);
            return v != null && v.ContainsKey("version") ? Convert.ToString(v["version"]) : null;
        }

        public bool Totals(out double down, out double up)
        {
            down = up = 0;
            var c = Get("/connections", 2000);
            if (c == null || !c.ContainsKey("downloadTotal") || !c.ContainsKey("uploadTotal")) return false;
            down = Convert.ToDouble(c["downloadTotal"]); up = Convert.ToDouble(c["uploadTotal"]);
            return true;
        }
    }

    // ---- состояние на диске ----
    class Store
    {
        public string Url, LocalPath; public bool UseLocal;
        static readonly JavaScriptSerializer Js = new JavaScriptSerializer();
        public static Store Load()
        {
            var s = new Store();
            try
            {
                var d = Js.DeserializeObject(File.ReadAllText(P.Settings)) as Dictionary<string, object>;
                if (d != null)
                {
                    if (d.ContainsKey("url")) s.Url = d["url"] as string;
                    if (d.ContainsKey("local")) s.LocalPath = d["local"] as string;
                    if (d.ContainsKey("mode")) s.UseLocal = (d["mode"] as string) == "local";
                }
            }
            catch { }
            return s;
        }
        public void Save()
        {
            try
            {
                Directory.CreateDirectory(P.DataDir);
                var d = new Dictionary<string, object>();
                d["url"] = Url; d["local"] = LocalPath; d["mode"] = UseLocal ? "local" : "remote";
                File.WriteAllText(P.Settings, Js.Serialize(d), Encoding.UTF8);
            }
            catch { }
        }
    }

    // ---- ядро: запуск/остановка/конфиг ----
    static class Core
    {
        static readonly object Gate = new object();

        public static bool Running()
        {
            var ps = Process.GetProcessesByName("mihomo");
            bool r = ps.Length > 0;
            foreach (var p in ps) p.Dispose();
            return r;
        }

        public static void Stop()
        {
            lock (Gate)
            {
                string o;
                Sys.Run("taskkill", "/F /IM mihomo.exe /T", out o, 15000);
                for (int i = 0; i < 20 && Running(); i++) Thread.Sleep(250);
            }
        }

        public static string Start()
        {
            lock (Gate)
            {
                if (!File.Exists(P.Cfg)) return "конфиг ещё не загружен";
                string exe = P.CoreExe();
                if (!File.Exists(exe)) return "не найдено ядро: " + exe;
                string o;
                int rc = Sys.Run(exe, "-t -d \"" + P.DataDir + "\" -f \"" + P.Cfg + "\"", out o, 60000);
                if (rc != 0) return "конфиг не прошёл проверку: " + Sys.LastLine(o);
                Stop();
                try { File.WriteAllText(P.Log, ""); } catch { }
                var psi = new ProcessStartInfo("cmd.exe",
                    "/c \"\"" + exe + "\" -d \"" + P.DataDir + "\" -f \"" + P.Cfg + "\" >> \"" + P.Log + "\" 2>&1\"");
                psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.WorkingDirectory = P.DataDir;
                try { Process.Start(psi).Dispose(); } catch (Exception ex) { return ex.Message; }
                for (int i = 0; i < 8; i++) Thread.Sleep(250);
                if (!Running()) return "mihomo завершился: " + LogTail();
                return null;
            }
        }

        // ---- установка ядра ----
        const string WintunUrl = "https://www.wintun.net/builds/wintun-0.14.1.zip";
        const string WintunSha256 = "07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51";

        public static string VersionOf(string exe)
        {
            if (!File.Exists(exe)) return null;
            string o;
            if (Sys.Run(exe, "-v", out o, 15000) != 0) return null;
            var m = System.Text.RegularExpressions.Regex.Match(o ?? "", @"v(\d+\.\d+\.\d+)");
            return m.Success ? m.Groups[1].Value : null;
        }

        static int Cmp(string a, string b) { return new Version(a).CompareTo(new Version(b)); }

        static byte[] Http(string url, int timeoutMs)
        {
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12 | (SecurityProtocolType)12288;
            var req = (HttpWebRequest)WebRequest.Create(url);
            req.UserAgent = "MihomoBar"; req.Timeout = timeoutMs; req.ReadWriteTimeout = timeoutMs;
            using (var resp = req.GetResponse())
            using (var s = resp.GetResponseStream())
            using (var ms = new MemoryStream()) { s.CopyTo(ms); return ms.ToArray(); }
        }

        static string Sha256(byte[] data)
        {
            using (var h = SHA256.Create()) return BitConverter.ToString(h.ComputeHash(data)).Replace("-", "").ToLowerInvariant();
        }

        // Скачивает последний релиз mihomo под эту архитектуру; проверяет SHA-256 из метаданных GitHub, если он там есть.
        static string DownloadCore(string exe)
        {
            string arch = P.Arch() == "arm64" ? "arm64" : "amd64";
            var rel = new JavaScriptSerializer().DeserializeObject(Encoding.UTF8.GetString(Http("https://api.github.com/repos/MetaCubeX/mihomo/releases/latest", 20000))) as Dictionary<string, object>;
            if (rel == null || !rel.ContainsKey("assets")) return "GitHub не вернул список файлов релиза";
            var rx = new System.Text.RegularExpressions.Regex("^mihomo-windows-" + arch + @"-v\d+\.\d+\.\d+\.zip$");
            string url = null, digest = null;
            foreach (object o in (IEnumerable)rel["assets"])
            {
                var a = o as Dictionary<string, object>;
                if (a == null || !rx.IsMatch(Convert.ToString(a["name"]))) continue;
                url = Convert.ToString(a["browser_download_url"]);
                digest = a.ContainsKey("digest") ? Convert.ToString(a["digest"]) : null;
                break;
            }
            if (url == null) return "в релизе нет mihomo-windows-" + arch;
            byte[] zip = Http(url, 180000);
            if (!string.IsNullOrEmpty(digest) && digest.StartsWith("sha256:") && Sha256(zip) != digest.Substring(7).ToLowerInvariant())
                return "контрольная сумма скачанного ядра не совпала";
            using (var za = new ZipArchive(new MemoryStream(zip)))
            {
                var entry = za.Entries.FirstOrDefault(e => e.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase));
                if (entry == null) return "в архиве нет exe";
                string tmp = exe + ".new";
                using (var src = entry.Open()) using (var dst = File.Create(tmp)) src.CopyTo(dst);
                if (VersionOf(tmp) == null) { File.Delete(tmp); return "скачанное ядро не запускается"; }
                if (File.Exists(exe)) File.Delete(exe);
                File.Move(tmp, exe);        // имя всегда mihomo.exe, а не mihomo-windows-*.exe
            }
            return null;
        }

        static string EnsureWintun()
        {
            string dll = Path.Combine(P.CoreDir(), "wintun.dll");
            if (File.Exists(dll)) return null;
            string seed = Path.Combine(P.SeedDir(), "wintun.dll");
            if (File.Exists(seed)) { File.Copy(seed, dll, true); return null; }
            byte[] zip = Http(WintunUrl, 120000);
            if (Sha256(zip) != WintunSha256) return "контрольная сумма wintun не совпала";
            using (var za = new ZipArchive(new MemoryStream(zip)))
            {
                var entry = za.GetEntry("wintun/bin/" + (P.Arch() == "arm64" ? "arm64" : "amd64") + "/wintun.dll");
                if (entry == null) return "в архиве wintun нет dll для этой архитектуры";
                using (var src = entry.Open()) using (var dst = File.Create(dll)) src.CopyTo(dst);
            }
            return null;
        }

        /// Ставит ядро, если его нет или не запускается: сперва копия из пакета, иначе загрузка с GitHub.
        /// Если рабочее ядро уже есть (в том числе обновлённое из панели), копия из пакета заменяет его только когда новее.
        public static string Ensure()
        {
            lock (Gate)
            {
                try
                {
                    Directory.CreateDirectory(P.CoreDir());
                    string exe = P.CoreExe();
                    string cur = VersionOf(exe);
                    string seedExe = Path.Combine(P.SeedDir(), "mihomo.exe");
                    string seedV = VersionOf(seedExe);
                    if (cur == null)
                    {
                        if (seedV != null) File.Copy(seedExe, exe, true);
                        else { string err = DownloadCore(exe); if (err != null) return err; }
                    }
                    else if (seedV != null && Cmp(seedV, cur) > 0)
                    {
                        Stop();
                        File.Copy(seedExe, exe, true);
                    }
                    return EnsureWintun();
                }
                catch (Exception ex) { return "установка ядра: " + ex.Message; }
            }
        }

        public static string LogTail()
        {
            try { return Sys.LastLine(File.ReadAllText(P.Log)); } catch { return "см. " + P.Log; }
        }

        // Проверяет и ставит конфиг; прежний — в резерв, если содержимое изменилось.
        public static string Install(byte[] data)
        {
            lock (Gate)
            {
                if (data == null || data.Length == 0) return "пустой конфиг";
                Directory.CreateDirectory(P.DataDir);
                string tmp = Path.Combine(P.DataDir, ".new.yaml");
                File.WriteAllBytes(tmp, data);
                string o;
                int rc = Sys.Run(P.CoreExe(), "-t -d \"" + P.DataDir + "\" -f \"" + tmp + "\"", out o, 60000);
                if (rc != 0) { try { File.Delete(tmp); } catch { } return "конфиг не прошёл проверку: " + Sys.LastLine(o); }
                if (File.Exists(P.Cfg) && !File.ReadAllBytes(P.Cfg).SequenceEqual(data)) File.Copy(P.Cfg, P.Prev, true);
                if (File.Exists(P.Cfg)) File.Delete(P.Cfg);
                File.Move(tmp, P.Cfg);
                return null;
            }
        }

        public static string Rollback()
        {
            lock (Gate)
            {
                if (!File.Exists(P.Prev)) return "нет прежнего конфига";
                string o;
                if (Sys.Run(P.CoreExe(), "-t -d \"" + P.DataDir + "\" -f \"" + P.Prev + "\"", out o, 60000) != 0) return "прежний конфиг не проходит проверку";
                string swap = P.Cfg + ".swap";
                if (File.Exists(P.Cfg)) File.Copy(P.Cfg, swap, true);
                File.Copy(P.Prev, P.Cfg, true);
                if (File.Exists(swap)) File.Copy(swap, P.Prev, true);
                try { File.Delete(swap); } catch { }
                return null;
            }
        }
    }

    // ---- аварийная блокировка интернета через Брандмауэр Windows ----
    static class Kill
    {
        // Блокируем весь публичный интернет; LAN, link-local, multicast и loopback остаются (DHCP/маршрутизатор живы).
        const string V4 = "1.0.0.0-9.255.255.255,11.0.0.0-126.255.255.255,128.0.0.0-169.253.255.255,169.255.0.0-172.15.255.255,172.32.0.0-192.167.255.255,192.169.0.0-223.255.255.255";
        const string V6 = "2000::/3";

        public static bool RuleExists()
        {
            string o;
            return Sys.Run("netsh", "advfirewall firewall show rule name=\"" + P.FwRule + "\"", out o, 15000) == 0;
        }

        static bool FirewallOn()
        {
            foreach (var prof in new[] { "StandardProfile", "PublicProfile", "DomainProfile" })
            {
                var v = Registry.GetValue(@"HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\" + prof, "EnableFirewall", 1);
                if (v is int && (int)v == 0) return false;
            }
            return true;
        }

        // Реальная проверка: публичный адрес не должен быть достижим.
        static bool InternetReachable()
        {
            try
            {
                using (var c = new TcpClient())
                {
                    var ar = c.BeginConnect("1.1.1.1", 443, null, null);
                    if (!ar.AsyncWaitHandle.WaitOne(2500)) return false;
                    c.EndConnect(ar); return true;
                }
            }
            catch { return false; }
        }

        public static string Block()
        {
            string o;
            Sys.Run("netsh", "advfirewall firewall delete rule name=\"" + P.FwRule + "\"", out o, 15000);
            string fail = null;
            if (!FirewallOn()) fail = "Брандмауэр Windows выключен";
            else if (Sys.Run("netsh", "advfirewall firewall add rule name=\"" + P.FwRule + "\" dir=out action=block enable=yes profile=any remoteip=" + V4 + "," + V6, out o, 20000) != 0)
                fail = "не удалось добавить правило: " + Sys.LastLine(o);
            else if (!RuleExists()) fail = "правило не создалось";
            else if (InternetReachable()) fail = "правило создано, но интернет всё ещё доступен";
            if (fail != null) { Unblock(); return fail; }
            return null;
        }

        public static string Unblock()
        {
            string o;
            Sys.Run("netsh", "advfirewall firewall delete rule name=\"" + P.FwRule + "\"", out o, 15000);
            return RuleExists() ? "правило не удалилось" : null;
        }
    }

    // ---- автозапуск при входе (планировщик, с правами администратора и без UAC) ----
    static class Autostart
    {
        public static bool Enabled()
        {
            string o; return Sys.Run("schtasks", "/Query /TN " + P.TaskName, out o, 15000) == 0;
        }

        public static string Set(bool on)
        {
            string o;
            if (!on) { Sys.Run("schtasks", "/Delete /TN " + P.TaskName + " /F", out o, 15000); return Enabled() ? "не удалось удалить задачу" : null; }
            string user = WindowsIdentity.GetCurrent().Name;
            string exe = Assembly.GetExecutingAssembly().Location;
            string xml =
"<?xml version=\"1.0\" encoding=\"UTF-16\"?>\n" +
"<Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">" +
"<Triggers><LogonTrigger><Enabled>true</Enabled><UserId>" + Esc(user) + "</UserId></LogonTrigger></Triggers>" +
"<Principals><Principal id=\"A\"><UserId>" + Esc(user) + "</UserId><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>" +
"<Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>" +
"<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Enabled>true</Enabled></Settings>" +
"<Actions Context=\"A\"><Exec><Command>" + Esc(exe) + "</Command></Exec></Actions></Task>";
            string tmp = Path.Combine(Path.GetTempPath(), "mihomobar-task.xml");
            File.WriteAllText(tmp, xml, Encoding.Unicode);
            int rc = Sys.Run("schtasks", "/Create /TN " + P.TaskName + " /XML \"" + tmp + "\" /F", out o, 20000);
            try { File.Delete(tmp); } catch { }
            return rc == 0 ? null : Sys.LastLine(o);
        }
        static string Esc(string s) { return s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;"); }
    }

    // ---- простое окно ввода ----
    class InputBox : Form
    {
        TextBox tb = new TextBox();
        public static string Ask(string title, string text, string value, string okText)
        {
            using (var f = new InputBox(title, text, value, okText))
                return f.ShowDialog() == DialogResult.OK ? f.tb.Text.Trim() : null;
        }
        InputBox(string title, string text, string value, string okText)
        {
            // Размеры считаем сами по DPI экрана: AutoScale на трей-приложении без главного окна ненадёжен.
            float k;
            using (var g = Graphics.FromHwnd(IntPtr.Zero)) k = g.DpiX / 96f;
            Func<int, int> sc = delegate(int v) { return (int)Math.Round(v * k); };
            AutoScaleMode = AutoScaleMode.None;
            Text = title; FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen; TopMost = true; ShowInTaskbar = true;
            ClientSize = new Size(sc(540), sc(150));
            var l = new Label { Text = text, Left = sc(12), Top = sc(12), Width = sc(516), Height = sc(40), AutoSize = false };
            tb.Left = sc(12); tb.Top = sc(58); tb.Width = sc(516); tb.Text = value ?? "";
            var ok = new Button { Text = okText, Left = sc(238), Top = sc(100), Width = sc(180), Height = sc(30), DialogResult = DialogResult.OK };
            var cancel = new Button { Text = "Отмена", Left = sc(428), Top = sc(100), Width = sc(100), Height = sc(30), DialogResult = DialogResult.Cancel };
            Controls.AddRange(new Control[] { l, tb, ok, cancel });
            AcceptButton = ok; CancelButton = cancel;
            Shown += delegate { Activate(); tb.Focus(); tb.SelectAll(); };
        }
    }

    class App : ApplicationContext
    {
        const int MaxAttempts = 5;
        readonly NotifyIcon tray = new NotifyIcon();
        readonly ContextMenuStrip menu = new ContextMenuStrip();
        readonly Control ui = new Control();
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        readonly Dictionary<string, Icon> icons = new Dictionary<string, Icon>();
        Store S = Store.Load();

        bool running, busy, recovering, blocked, desired, apiOK, firstRefresh = true;
        string exitNode, note, speed, ipLine, lastError, coreVersion;
        int attempts; DateTime? stableSince;
        bool haveLast; double lastDown, lastUp; DateTime lastAt;

        bool InFlight { get { return busy || recovering; } }
        bool HasConfig { get { return File.Exists(P.Cfg); } }
        bool HasPrev { get { return File.Exists(P.Prev); } }

        public App()
        {
            Directory.CreateDirectory(P.DataDir);
            ui.CreateControl(); var h = ui.Handle;
            foreach (var k in new[] { "off", "on", "busy", "blocked" }) icons[k] = MakeIcon(k);
            tray.Icon = icons["off"]; tray.Text = "MihomoBar"; tray.Visible = true;
            tray.ContextMenuStrip = menu;
            menu.Opening += delegate { Rebuild(true); Refresh(); };
            timer.Interval = 3000; timer.Tick += delegate { Refresh(); }; timer.Start();
            Rebuild(true);
            Refresh();
            Task.Run(delegate { string v = Core.VersionOf(P.CoreExe()); UI(delegate { if (coreVersion == null && v != null) coreVersion = "v" + v; }); });
            Task.Run(delegate
            {
                if (Kill.RuleExists()) UI(delegate { blocked = true; Rebuild(false); OfferUnblock(); });
            });
            if (string.IsNullOrEmpty(S.Url) && !S.UseLocal) UI(delegate { AskUrl(true); });
        }

        void UI(Action a) { if (ui.IsHandleCreated) ui.BeginInvoke(a); }

        // ---------- значок ----------
        static Icon MakeIcon(string kind)
        {
            using (var bmp = new Bitmap(32, 32))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    Color c = kind == "on" ? Color.FromArgb(46, 184, 92) : kind == "blocked" ? Color.FromArgb(220, 53, 69)
                            : kind == "busy" ? Color.FromArgb(240, 173, 78) : Color.FromArgb(150, 150, 150);
                    var shield = new PointF[] { new PointF(16, 2), new PointF(28, 6), new PointF(28, 16), new PointF(16, 30), new PointF(4, 16), new PointF(4, 6) };
                    using (var br = new SolidBrush(c)) if (kind != "off") g.FillPolygon(br, shield);
                    using (var pen = new Pen(c, 3f)) g.DrawPolygon(pen, shield);
                    if (kind == "blocked") using (var f = new Font("Segoe UI", 15, FontStyle.Bold, GraphicsUnit.Pixel))
                        g.DrawString("!", f, Brushes.White, 12f, 6f);
                }
                IntPtr hi = bmp.GetHicon();
                var icon = (Icon)Icon.FromHandle(hi).Clone();
                DestroyIcon(hi);
                return icon;
            }
        }
        [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);

        void Notify(string title, string text) { try { tray.ShowBalloonTip(6000, title, text, ToolTipIcon.Info); } catch { } }

        void Alert(string text)
        {
            lastError = text;
            using (var owner = new Form { TopMost = true, ShowInTaskbar = false, StartPosition = FormStartPosition.CenterScreen, Opacity = 0, Size = new Size(1, 1) })
            { owner.Show(); MessageBox.Show(owner, text, "MihomoBar", MessageBoxButtons.OK, MessageBoxIcon.Information); }
        }
        DialogResult Ask(string text, MessageBoxButtons b)
        {
            using (var owner = new Form { TopMost = true, ShowInTaskbar = false, StartPosition = FormStartPosition.CenterScreen, Opacity = 0, Size = new Size(1, 1) })
            { owner.Show(); return MessageBox.Show(owner, text, "MihomoBar", b, MessageBoxIcon.Question); }
        }

        // ---------- опрос состояния ----------
        void Refresh()
        {
            Task.Run(delegate
            {
                bool up = Core.Running();
                Controller c = up ? Controller.Load() : null;
                string node = c != null ? c.ExitNode() : null;
                string liveVer = c != null ? c.Version() : null;
                double d = 0, u = 0; bool ok = c != null && c.Totals(out d, out u);
                DateTime now = DateTime.UtcNow;
                UI(delegate
                {
                    string sp = null;
                    if (ok && haveLast && (now - lastAt).TotalSeconds > 0.5)
                    {
                        double dt = (now - lastAt).TotalSeconds;
                        sp = "↓ " + Rate((d - lastDown) / dt) + "  ↑ " + Rate((u - lastUp) / dt);
                    }
                    haveLast = ok; lastDown = d; lastUp = u; lastAt = now;
                    if (liveVer != null) coreVersion = liveVer;      // после обновления из панели показываем актуальную версию
                    running = up; exitNode = node; speed = up ? sp : null; apiOK = node != null;
                    if (firstRefresh) { firstRefresh = false; if (up) desired = true; }   // подхватываем уже работающий mihomo
                    Watchdog();
                    Rebuild(false);
                });
            });
        }

        static string Rate(double bps)
        {
            double v = Math.Max(bps, 0);
            if (v >= 1048576) return (v / 1048576).ToString("0.0") + " МБ/с";
            if (v >= 1024) return (v / 1024).ToString("0") + " КБ/с";
            return v.ToString("0") + " Б/с";
        }

        // ---------- автоперезапуск и блокировка ----------
        void Watchdog()
        {
            if (!desired || busy || blocked || recovering) return;
            if (running)
            {
                if (stableSince == null) stableSince = DateTime.UtcNow;
                if ((DateTime.UtcNow - stableSince.Value).TotalSeconds > 60) attempts = 0;
                return;
            }
            stableSince = null;
            attempts++;
            if (attempts > MaxAttempts) { LockDown(); return; }
            recovering = true;
            note = "mihomo упал — перезапуск " + attempts + "/" + MaxAttempts;
            Notify("MihomoBar", "mihomo упал. Перезапуск " + attempts + " из " + MaxAttempts);
            int n = attempts;
            Task.Run(delegate
            {
                string err = Core.Start();
                UI(delegate
                {
                    recovering = false;
                    if (err == null) { note = "Перезапущен после сбоя (попытка " + n + ")"; Notify("MihomoBar", "Прокси снова работает"); }
                    else lastError = err;
                    Refresh();
                });
            });
        }

        void LockDown()
        {
            desired = false; blocked = true; busy = true; Rebuild(false);
            Task.Run(delegate
            {
                Core.Stop();
                string err = Kill.Block();
                UI(delegate
                {
                    busy = false; blocked = err == null;
                    if (err == null)
                    {
                        note = "Интернет заблокирован после " + MaxAttempts + " неудачных перезапусков";
                        Notify("MihomoBar — интернет заблокирован", "Прокси не удалось поднять за " + MaxAttempts + " попыток. Блокировка снимется при выходе из программы.");
                    }
                    else
                    {
                        lastError = err;
                        note = "⚠ Прокси не работает, а заблокировать интернет не удалось: " + err;
                        Notify("MihomoBar — ВНИМАНИЕ", "Прокси упал, интернет НЕ заблокирован: " + err);
                    }
                    Rebuild(false);
                });
            });
        }

        void OfferUnblock()
        {
            if (Ask("Интернет заблокирован после прошлого сбоя. Снять блокировку?", MessageBoxButtons.YesNo) != DialogResult.Yes) return;
            Task.Run(delegate
            {
                string err = Kill.Unblock();
                UI(delegate
                {
                    if (err != null) Alert("Не удалось снять блокировку: " + err + "\nВ консоли администратора: netsh advfirewall firewall delete rule name=" + P.FwRule);
                    else { blocked = false; attempts = 0; }
                    Rebuild(false);
                });
            });
        }

        // ---------- конфиг ----------
        byte[] FetchSource(out string failure)
        {
            failure = null;
            if (S.UseLocal && !string.IsNullOrEmpty(S.LocalPath))
            {
                try { var d = File.ReadAllBytes(S.LocalPath); if (d.Length > 0) return d; failure = "файл пустой"; }
                catch (Exception ex) { failure = "не удалось прочитать " + S.LocalPath + ": " + ex.Message; }
                return null;
            }
            Uri uri;
            if (string.IsNullOrEmpty(S.Url) || !Uri.TryCreate(S.Url, UriKind.Absolute, out uri) || (uri.Scheme != "http" && uri.Scheme != "https"))
            { failure = "ссылка на конфиг не задана"; return null; }
            try
            {
                ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12 | (SecurityProtocolType)12288;   // TLS 1.2 + 1.3
                var req = (HttpWebRequest)WebRequest.Create(uri);
                req.UserAgent = "clash.meta"; req.Timeout = 20000; req.ReadWriteTimeout = 20000;
                using (var resp = (HttpWebResponse)req.GetResponse())
                using (var s = resp.GetResponseStream())
                using (var ms = new MemoryStream())
                {
                    s.CopyTo(ms);
                    if (ms.Length == 0) { failure = "пустой ответ"; return null; }
                    return ms.ToArray();
                }
            }
            catch (WebException ex)
            {
                var hr = ex.Response as HttpWebResponse;
                failure = hr != null ? "HTTP " + (int)hr.StatusCode : ex.Message;
                return null;
            }
            catch (Exception ex) { failure = ex.Message; return null; }
        }

        string UpdateConfig()
        {
            string failure; var data = FetchSource(out failure);
            if (data == null) return failure;
            return Core.Install(data);
        }

        static string Hhmm() { return DateTime.Now.ToString("HH:mm"); }

        void StartFlow()
        {
            if (InFlight) return;
            busy = true; Rebuild(false);
            Task.Run(delegate
            {
                UI(delegate { note = "Проверяю ядро…"; Rebuild(false); });
                string coreErr = Core.Ensure();
                if (coreErr != null)
                {
                    UI(delegate
                    {
                        busy = false; desired = false; note = "Ядро не установлено: " + coreErr;
                        Notify("MihomoBar", "Не удалось установить ядро mihomo");
                        Alert("Не удалось установить ядро mihomo: " + coreErr);
                        Refresh();
                    });
                    return;
                }
                string cv = Core.VersionOf(P.CoreExe());
                if (cv != null) UI(delegate { coreVersion = "v" + cv; });
                byte[] before = File.Exists(P.Cfg) ? File.ReadAllBytes(P.Cfg) : null;
                string failure = UpdateConfig();
                byte[] after = File.Exists(P.Cfg) ? File.ReadAllBytes(P.Cfg) : null;
                bool changed = failure == null && (before == null || after == null || !before.SequenceEqual(after));
                bool usable = failure == null || HasConfig;
                string error = null; bool rolledBack = false;
                if (usable)
                {
                    error = Core.Start();
                    // новый конфиг прошёл проверку, но ядро не поднялось — возвращаем прежний
                    if (error != null && changed && HasPrev && Core.Rollback() == null)
                    { error = Core.Start(); rolledBack = error == null; }
                }
                UI(delegate
                {
                    busy = false; desired = usable && error == null;
                    attempts = 0; stableSince = null; ipLine = null;
                    if (error != null) Notify("MihomoBar", "Не удалось запустить: " + error);
                    if (rolledBack) { note = "Новый конфиг не запустился — автоматически восстановлен прежний"; Notify("MihomoBar", "Новый конфиг не запустился, восстановлен прежний"); }
                    else if (failure != null) note = HasConfig ? "Конфиг не обновлён (" + failure + ") — используется прежний" : null;
                    else note = (S.UseLocal ? "Локальный конфиг загружен " : "Конфиг обновлён ") + Hhmm();
                    if (!usable) Alert("Не удалось получить конфиг: " + failure);
                    else if (error != null) Alert(error);
                    Refresh();
                });
            });
        }

        // ---------- действия ----------
        void ToggleProxy()
        {
            if (InFlight || blocked) return;
            if (running)
            {
                desired = false; busy = true; Rebuild(false);
                Task.Run(delegate { Core.Stop(); UI(delegate { busy = false; Refresh(); }); });
            }
            else
            {
                if (string.IsNullOrEmpty(S.Url) && !S.UseLocal) { AskUrl(true); return; }
                StartFlow();
            }
        }

        void UpdateAndRestart()
        {
            if (InFlight || blocked) return;
            if (string.IsNullOrEmpty(S.Url) && !S.UseLocal) { AskUrl(true); return; }
            StartFlow();
        }

        void DoRollback()
        {
            if (InFlight || blocked) return;
            busy = true; Rebuild(false);
            Task.Run(delegate
            {
                string err = Core.Rollback();
                bool was = Core.Running();
                if (err == null && was) err = Core.Start();
                UI(delegate
                {
                    busy = false;
                    if (err != null) Alert(err); else note = "Выполнен откат к прежнему конфигу " + Hhmm();
                    Refresh();
                });
            });
        }

        void AskUrl(bool firstRun)
        {
            if (InFlight) return;
            string s = InputBox.Ask(firstRun ? "Ссылка на конфиг" : "Изменить ссылку на конфиг",
                "Конфиг mihomo (YAML) будет скачиваться по этой ссылке при каждом запуске.", S.Url,
                firstRun ? "Скачать и запустить" : "Сохранить и перезапустить");
            if (s == null) return;
            Uri u;
            if (!Uri.TryCreate(s, UriKind.Absolute, out u) || (u.Scheme != "http" && u.Scheme != "https")) { Alert("Нужна ссылка http(s)://…"); return; }
            S.Url = s; S.UseLocal = false; S.Save();
            StartFlow();
        }

        void PickLocal()
        {
            if (InFlight) return;
            using (var d = new OpenFileDialog { Title = "Выберите локальный конфиг mihomo", Filter = "YAML (*.yaml;*.yml)|*.yaml;*.yml|Все файлы|*.*" })
            {
                using (var owner = new Form { TopMost = true, ShowInTaskbar = false, StartPosition = FormStartPosition.CenterScreen, Opacity = 0, Size = new Size(1, 1) })
                {
                    owner.Show();
                    if (d.ShowDialog(owner) != DialogResult.OK) return;
                }
                S.LocalPath = d.FileName; S.UseLocal = true; S.Save();
            }
            StartFlow();
        }

        void SelectSource(bool local)
        {
            if (InFlight) return;
            S.UseLocal = local; S.Save(); StartFlow();
        }

        void CheckIp()
        {
            Controller c = Controller.Load();
            if (!running || c == null) return;
            ipLine = "Проверка IP…"; Rebuild(false);
            int port = c.MixedPort;
            Task.Run(delegate
            {
                string result = null;
                // Первым — Cloudflare по IP-адресу: DNS не нужен, поэтому DNS-блок-листы не мешают.
                var services = new List<KeyValuePair<string, Func<string, string>>>();
                services.Add(new KeyValuePair<string, Func<string, string>>("https://1.1.1.1/cdn-cgi/trace", delegate(string t)
                {
                    var kv = new Dictionary<string, string>();
                    foreach (var l in t.Split('\n')) { int i = l.IndexOf('='); if (i > 0) kv[l.Substring(0, i).Trim()] = l.Substring(i + 1).Trim(); }
                    if (!kv.ContainsKey("ip")) return null;
                    return string.Join(" · ", new[] { kv["ip"], kv.ContainsKey("loc") ? kv["loc"] : null, kv.ContainsKey("colo") ? kv["colo"] : null }.Where(x => x != null).ToArray());
                }));
                Func<string, string> json = delegate(string t)
                {
                    var o = new JavaScriptSerializer().DeserializeObject(t) as Dictionary<string, object>;
                    if (o == null || !o.ContainsKey("ip")) return null;
                    return string.Join(" · ", new[] { Convert.ToString(o["ip"]), o.ContainsKey("country") ? Convert.ToString(o["country"]) : null, o.ContainsKey("city") ? Convert.ToString(o["city"]) : null }.Where(x => x != null).ToArray());
                };
                services.Add(new KeyValuePair<string, Func<string, string>>("https://ipinfo.io/json", json));
                services.Add(new KeyValuePair<string, Func<string, string>>("https://ipwho.is/", json));
                ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12 | (SecurityProtocolType)12288;
                foreach (var sv in services)
                {
                    try
                    {
                        var req = (HttpWebRequest)WebRequest.Create(sv.Key);
                        req.Proxy = new WebProxy("127.0.0.1", port); req.Timeout = 10000; req.UserAgent = "curl/8";
                        using (var resp = req.GetResponse())
                        using (var rd = new StreamReader(resp.GetResponseStream()))
                            result = sv.Value(rd.ReadToEnd());
                        if (result != null) break;
                    }
                    catch { }
                }
                UI(delegate { ipLine = result != null ? "IP выхода: " + result : "IP не определён — сервис недоступен через прокси"; Rebuild(false); });
            });
        }

        void OpenPanel()
        {
            var c = Controller.Load();
            if (c == null) return;
            try { Process.Start(c.Base + "/ui"); } catch { }
        }

        void ToggleAutostart()
        {
            string err = Autostart.Set(!Autostart.Enabled());
            if (err != null) Alert("Автозапуск: " + err);
            Rebuild(false);
        }

        void Quit()
        {
            // Сначала спрашиваем — состояние (desired, блокировка) меняем только после подтверждения выхода.
            bool stopCore = false;
            if (Core.Running())
            {
                var r = Ask("Прокси ещё работает.\n\nДа — остановить mihomo и выйти\nНет — выйти, оставив работать\nОтмена — вернуться\n\n(Если оставить работать, TUN продолжит действовать без значка в трее.)", MessageBoxButtons.YesNoCancel);
                if (r == DialogResult.Cancel) return;
                stopCore = r == DialogResult.Yes;
            }
            desired = false; timer.Stop();
            if (stopCore) Core.Stop();
            if (blocked)
            {
                string err = Kill.Unblock();
                if (err != null)
                {
                    try { Clipboard.SetText("netsh advfirewall firewall delete rule name=" + P.FwRule); } catch { }
                    Alert("Не удалось снять блокировку: " + err + "\nКоманда для консоли администратора скопирована в буфер:\nnetsh advfirewall firewall delete rule name=" + P.FwRule);
                }
            }
            tray.Visible = false; tray.Dispose();
            Application.Exit();
        }

        // ---------- меню ----------
        void Rebuild(bool force)
        {
            string key = blocked ? "blocked" : busy ? "busy" : running ? "on" : "off";
            tray.Icon = icons[key];
            tray.Text = "MihomoBar: " + (blocked ? "интернет заблокирован" : running ? "работает" + (exitNode != null ? " (" + exitNode + ")" : "") : "остановлен");
            if (menu.Visible && !force) return;

            menu.Items.Clear();
            Action<string> info = delegate(string t) { menu.Items.Add(new ToolStripMenuItem(t) { Enabled = false }); };
            Func<string, Action, bool, ToolStripMenuItem> act = delegate(string t, Action a, bool en)
            { var m = new ToolStripMenuItem(t) { Enabled = en }; m.Click += delegate { a(); }; menu.Items.Add(m); return m; };

            info(blocked ? "⛔ Интернет заблокирован" : running ? "Работает" : "Остановлен");
            if (blocked) info("Блокировка снимется при выходе из программы");
            if (running) info("Исходящий прокси: " + (exitNode ?? "неизвестно"));
            if (running && speed != null) info(speed);
            if (ipLine != null) info(ipLine);
            string host = null; Uri uu;
            if (!string.IsNullOrEmpty(S.Url) && Uri.TryCreate(S.Url, UriKind.Absolute, out uu)) host = uu.Host;
            bool local = S.UseLocal && !string.IsNullOrEmpty(S.LocalPath);
            info(local ? "Конфиг: локальный — " + Path.GetFileName(S.LocalPath) : "Конфиг: удалённый — " + (host ?? "ссылка не задана"));
            if (note != null) info(note);
            menu.Items.Add(new ToolStripSeparator());

            bool free = !InFlight && !blocked;
            act(running ? "Выключить прокси" : "Включить прокси", ToggleProxy, free);
            act("Обновить конфиг и перезапустить", UpdateAndRestart, free);
            act("Откатить к прежнему конфигу", DoRollback, free && HasPrev);
            act("Проверить IP выхода", CheckIp, running);
            act("Ссылка на конфиг…", delegate { AskUrl(false); }, !InFlight);
            act("Использовать локальный конфиг…", PickLocal, !InFlight);
            var src = new ToolStripMenuItem("Источник конфига");
            var r1 = new ToolStripMenuItem("Удалённый — " + (host ?? "не задана")) { Checked = !local, Enabled = host != null && !InFlight };
            r1.Click += delegate { SelectSource(false); };
            var r2 = new ToolStripMenuItem("Локальный — " + (string.IsNullOrEmpty(S.LocalPath) ? "не выбран" : Path.GetFileName(S.LocalPath))) { Checked = local, Enabled = !string.IsNullOrEmpty(S.LocalPath) && !InFlight };
            r2.Click += delegate { SelectSource(true); };
            src.DropDownItems.Add(r1); src.DropDownItems.Add(r2);
            menu.Items.Add(src);
            act("Открыть панель", OpenPanel, running);

            var diag = new ToolStripMenuItem("Диагностика");
            Action<string> dinfo = delegate(string t) { diag.DropDownItems.Add(new ToolStripMenuItem(t) { Enabled = false }); };
            dinfo("Права администратора: " + (new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator) ? "да" : "НЕТ — TUN не заработает"));
            dinfo("Ядро: " + (File.Exists(P.CoreExe()) ? (coreVersion ?? "версия неизвестна") : "не установлено — скачается при включении"));
            dinfo("Путь ядра: " + P.CoreExe());
            dinfo("wintun.dll: " + (File.Exists(Path.Combine(P.CoreDir(), "wintun.dll")) ? "найден" : "НЕ НАЙДЕН"));
            dinfo("API ядра: " + (running ? (apiOK ? "доступен" : "не отвечает") : "ядро остановлено"));
            dinfo("Блокировка интернета: " + (blocked ? "включена" : "выключена"));
            dinfo("Последняя ошибка: " + (lastError == null ? "нет" : (lastError.Length > 70 ? lastError.Substring(0, 70) : lastError).Replace("\n", " ")));
            diag.DropDownItems.Add(new ToolStripSeparator());
            var lg = new ToolStripMenuItem("Показать лог ядра"); lg.Click += delegate { try { Process.Start("notepad.exe", "\"" + P.Log + "\""); } catch { } };
            var cf = new ToolStripMenuItem("Показать конфиг в проводнике"); cf.Click += delegate { try { Process.Start("explorer.exe", "/select,\"" + P.Cfg + "\""); } catch { } };
            diag.DropDownItems.Add(lg); diag.DropDownItems.Add(cf);
            menu.Items.Add(diag);

            menu.Items.Add(new ToolStripSeparator());
            var auto = new ToolStripMenuItem("Запускать при входе") { Checked = Autostart.Enabled() };
            auto.Click += delegate { ToggleAutostart(); };
            menu.Items.Add(auto);
            act("Выход", Quit, true);
        }
    }

    // Скрытая самопроверка: MihomoBar.exe --selftest <config.yaml> <отчёт.txt>
    // Прогоняет установку конфига, запуск ядра, API, блокировку/разблокировку и остановку без GUI.
    static class SelfTest
    {
        public static void Run(string cfgPath, string report)
        {
            var log = new StringBuilder();
            Action<string, string> step = delegate(string name, string err)
            { log.AppendLine((err == null ? "OK   " : "FAIL ") + name + (err == null ? "" : ": " + err)); };
            try
            {
                Directory.CreateDirectory(P.DataDir);
                step("ensure-core", Core.Ensure());
                step("core-version", Core.VersionOf(P.CoreExe()) != null ? null : "ядро не запускается");
                step("install-config", Core.Install(File.ReadAllBytes(cfgPath)));
                step("start", Core.Start());
                step("running", Core.Running() ? null : "ядро не работает");
                Thread.Sleep(3000);
                var c = Controller.Load();
                string node = c == null ? null : c.ExitNode();
                step("api /proxies", c != null && node != null ? null : "нет ответа (node=" + node + ")");
                double d, u;
                step("api /connections", c != null && c.Totals(out d, out u) ? null : "нет ответа");
                step("block", Kill.Block());
                step("rule-exists", Kill.RuleExists() ? null : "правило не найдено");
                step("unblock", Kill.Unblock());
                step("rule-removed", Kill.RuleExists() ? "правило осталось" : null);
                step("autostart-on", Autostart.Set(true)); step("autostart-enabled", Autostart.Enabled() ? null : "задача не найдена");
                step("autostart-off", Autostart.Set(false)); step("autostart-removed", Autostart.Enabled() ? "задача осталась" : null);
                step("stop", null); Core.Stop();
                step("stopped", Core.Running() ? "ядро всё ещё работает" : null);
            }
            catch (Exception ex) { log.AppendLine("EXCEPTION " + ex); }
            File.WriteAllText(report, log.ToString(), Encoding.UTF8);
        }
    }

    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            if (args.Length == 3 && args[0] == "--selftest") { SelfTest.Run(args[1], args[2]); return; }
            bool created;
            using (var mutex = new Mutex(true, @"Global\MihomoBar", out created))
            {
                if (!created) return;
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new App());
            }
        }
    }
}
