using System;
using System.Diagnostics;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

namespace Lidless
{
    internal static class App
    {
        public static string ExePath => Application.ExecutablePath;
        public const string Version = "0.1.0";
    }

    internal static class Program
    {
        /// <summary>
        /// Lidless.exe                         run the tray app (or show it if already running)
        /// Lidless.exe lidless://start?...     URL scheme, forwarded to the running app
        /// Lidless.exe hook hold|refresh|release   Claude Code hook, reads the hook JSON from stdin
        /// Lidless.exe --watchdog PID          restores the lid setting if PID dies mid-session
        /// </summary>
        [STAThread]
        private static int Main(string[] args)
        {
            try
            {
                if (args.Length >= 2 && args[0] == "--watchdog") return Watchdog(args[1]);
                if (args.Length >= 1 && args[0] == "hook") return Hook(args.Length > 1 ? args[1] : "hold");
                if (args.Length >= 1 && args[0].StartsWith("lidless:", StringComparison.OrdinalIgnoreCase))
                    return Url(args[0]);
            }
            catch (Exception)
            {
                return 0;
            }

            using (var mutex = new Mutex(true, @"Local\Lidless-" + Environment.UserName, out bool first))
            {
                if (!first)
                {
                    Ipc.Send("show");
                    return 0;
                }
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new TrayApp());
                GC.KeepAlive(mutex);
            }
            return 0;
        }

        /// <summary>lidless://start?minutes=90&amp;lid=1, lidless://stop, lidless://hold?id=X, lidless://release?id=X, lidless://show</summary>
        private static int Url(string url)
        {
            Uri uri;
            if (!Uri.TryCreate(url, UriKind.Absolute, out uri)) return 0;
            string action = uri.Host.ToLowerInvariant();
            string Query(string name)
            {
                var match = Regex.Match(uri.Query, "[?&]" + name + "=([^&]*)");
                return match.Success ? Uri.UnescapeDataString(match.Groups[1].Value) : null;
            }
            switch (action)
            {
                case "start":
                    Ipc.SendOrLaunch($"start {Query("minutes") ?? "0"} {Query("lid") ?? "-"}");
                    break;
                case "stop": Ipc.Send("stop"); break;
                case "extend": Ipc.Send($"extend {Query("minutes") ?? "15"}"); break;
                case "hold":
                    var holdId = Rules.SanitizeId(Query("id"));
                    if (holdId != null) Ipc.SendOrLaunch($"hold {holdId} {Query("minutes") ?? "120"}");
                    break;
                case "release":
                    var releaseId = Rules.SanitizeId(Query("id"));
                    if (releaseId != null) Ipc.Send($"release {releaseId}");
                    break;
                default: Ipc.SendOrLaunch("show"); break;
            }
            return 0;
        }

        /// <summary>Claude Code hook. Silent and always exits 0 so it never blocks the agent.</summary>
        private static int Hook(string action)
        {
            string input = "";
            try
            {
                if (Console.IsInputRedirected) input = Console.In.ReadToEnd();
            }
            catch (Exception) { }
            var match = Regex.Match(input, "\"session_id\"\\s*:\\s*\"([A-Za-z0-9_-]{1,64})\"");
            string id = match.Success ? match.Groups[1].Value : "claude";
            string stamp = Path.Combine(Path.GetTempPath(), "lidless-hook-" + id);

            switch (action)
            {
                case "hold":
                    Touch(stamp);
                    Ipc.SendOrLaunch("hold " + id + " 120");
                    break;
                case "refresh":
                    if (!File.Exists(stamp) || DateTime.UtcNow - File.GetLastWriteTimeUtc(stamp) > TimeSpan.FromMinutes(5))
                    {
                        Touch(stamp);
                        Ipc.SendOrLaunch("hold " + id + " 120");
                    }
                    break;
                case "release":
                    try { File.Delete(stamp); } catch (Exception) { }
                    Ipc.Send("release " + id);
                    break;
            }
            return 0;
        }

        private static void Touch(string path)
        {
            try { File.WriteAllText(path, DateTime.UtcNow.ToString("o")); } catch (Exception) { }
        }

        /// <summary>Started next to a closed-lid session. If the app dies, it puts the lid setting back.</summary>
        private static int Watchdog(string pidText)
        {
            if (!int.TryParse(pidText, out int pid)) return 0;
            Process parent;
            try { parent = Process.GetProcessById(pid); }
            catch (Exception) { parent = null; }

            while (true)
            {
                if (!Power.HasJournal()) return 0; // the app restored it, nothing to guard
                bool alive = parent != null && !parent.HasExited;
                if (!alive)
                {
                    for (int i = 0; i < 10 && !Power.Restore(); i++) Thread.Sleep(1000);
                    return 0;
                }
                Thread.Sleep(2000);
            }
        }
    }
}
