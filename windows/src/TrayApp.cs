using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Linq;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Lidless
{
    /// <summary>The tray icon, its menu and the session logic.</summary>
    internal sealed class TrayApp : ApplicationContext
    {
        private static readonly int[] TimerPresets = { 15, 30, 60, 120, 240, 480 };
        private static readonly int[] ClosedLimits = { 30, 60, 120, 240, 480, 0 };
        private static readonly int[] Cutoffs = { 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80 };

        private sealed class Session
        {
            public DateTime Started;
            public DateTime? Ends;
            public bool? LidOverride;
            public bool StartedByAgents;
        }

        private readonly NotifyIcon tray;
        private readonly ContextMenuStrip menu = new ContextMenuStrip();
        private readonly System.Windows.Forms.Timer ticker = new System.Windows.Forms.Timer { Interval = 1000 };
        private readonly LidWatcher lid = new LidWatcher();
        private readonly SynchronizationContext ui;
        private readonly Icon idleIcon = Icons.Make(false);
        private readonly Icon activeIcon = Icons.Make(true);
        private readonly Dictionary<string, DateTime> agentHolds = new Dictionary<string, DateTime>();

        private Session session;
        private PowerSnapshot power = Power.Snapshot();
        private bool lidApplied;
        private string lidError;
        private int ticks;
        private Font boldFont;

        public TrayApp()
        {
            ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();

            // A journal left by a crash or power loss means the lid setting may still be "Do nothing".
            Power.Restore();
            Settings.RegisterUrlScheme();
            Settings.RefreshStartWithWindows();
            if (ClaudeHooks.IsInstalled() && !ClaudeHooks.IsInstalled(HookExePath))
            {
                try { ClaudeHooks.Install(HookExePath); } catch (Exception) { } // the exe moved
            }

            tray = new NotifyIcon { Icon = idleIcon, Text = "Lidless: idle", Visible = true, ContextMenuStrip = menu };
            tray.MouseUp += (s, e) =>
            {
                if (e.Button == MouseButtons.Left) ShowMenu();
            };
            menu.Opening += (s, e) =>
            {
                BuildMenu();
                e.Cancel = false; // WinForms cancels opening a menu that was empty a moment ago
            };

            ticker.Tick += (s, e) => Tick();
            ticker.Start();
            lid.Changed += OnLidChanged;
            SystemEvents.PowerModeChanged += OnPowerModeChanged;

            Ipc.Serve(line => ui.Post(_ => Handle(line), null));
        }

        // MARK: Commands from hooks, URLs and second instances

        private void Handle(string line)
        {
            var parts = line.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length == 0) return;
            switch (parts[0])
            {
                case "show":
                    ShowMenu();
                    break;
                case "start":
                {
                    int minutes = parts.Length > 1 && int.TryParse(parts[1], out int m) ? Math.Min(Math.Max(m, 0), 1440) : 0;
                    bool? lidFlag = parts.Length > 2 && parts[2] != "-" ? (bool?)(parts[2] == "1" || parts[2] == "true") : null;
                    End(StopReason.None);
                    Start(minutes == 0 ? (DateTime?)null : DateTime.Now.AddMinutes(minutes), lidFlag, false);
                    break;
                }
                case "stop":
                    agentHolds.Clear();
                    End(StopReason.None);
                    break;
                case "extend":
                    Extend(parts.Length > 1 && int.TryParse(parts[1], out int add) ? add : 15);
                    break;
                case "hold":
                {
                    if (parts.Length < 2) return;
                    string id = Rules.SanitizeId(parts[1]);
                    if (id == null) return;
                    int minutes = parts.Length > 2 && int.TryParse(parts[2], out int hm) ? Math.Min(Math.Max(hm, 1), 1440) : 120;
                    agentHolds[id] = DateTime.UtcNow.AddMinutes(minutes);
                    if (session == null) Start(null, null, true);
                    break;
                }
                case "release":
                {
                    if (parts.Length < 2) return;
                    agentHolds.Remove(parts[1]);
                    // Stop fires after every reply, so no balloon here.
                    EndAgentSessionIfIdle(StopReason.None);
                    break;
                }
            }
            UpdateTray();
        }

        // MARK: Session

        private static string HookExePath => Native.ShortPath(App.ExePath);

        private bool ClosedLidActive => session?.LidOverride ?? Settings.ClosedLidEnabled;

        private void Start(DateTime? ends, bool? lidOverride, bool byAgents)
        {
            power = Power.Snapshot();
            var violation = Rules.SessionViolation(power, Settings.RequireCharger, Settings.EndOnLowBattery, Settings.BatteryCutoff);
            if (violation == StopReason.ChargerRequired)
            {
                Notify("Connect a charger, or turn off “Require charger”.");
                return;
            }
            if (violation == StopReason.LowBattery)
            {
                Notify($"Battery is at or below {Settings.BatteryCutoff}%. Connect a charger or lower the cutoff.");
                return;
            }
            session = new Session { Started = DateTime.Now, Ends = ends, LidOverride = lidOverride, StartedByAgents = byAgents };
            Power.KeepAwake(Settings.KeepDisplayOn);
            SyncLid();
            UpdateTray();
        }

        private void Extend(int minutes)
        {
            if (session?.Ends == null) return;
            var limit = DateTime.Now.AddHours(24);
            var next = session.Ends.Value.AddMinutes(minutes);
            session.Ends = next > limit ? limit : next;
            UpdateTray();
        }

        private void End(StopReason reason)
        {
            if (session == null) return;
            session = null;
            Power.AllowSleep();
            RestoreLid();
            UpdateTray();
            string message = Rules.Message(reason, Settings.BatteryCutoff);
            if (message.Length > 0) Notify(message);
        }

        private void EndAgentSessionIfIdle(StopReason reason)
        {
            if (session != null && session.StartedByAgents && agentHolds.Count == 0) End(reason);
        }

        /// <summary>Applies or restores the lid action to match the session and settings.</summary>
        private void SyncLid()
        {
            bool want = session != null && ClosedLidActive && power.HasBattery;
            if (want && !lidApplied)
            {
                lidError = Power.ApplyLidDoNothing();
                lidApplied = lidError == null;
                if (lidApplied) StartWatchdog();
            }
            else if (!want && lidApplied)
            {
                RestoreLid();
            }
        }

        private void RestoreLid()
        {
            if (Power.Restore()) lidApplied = false;
        }

        private void StartWatchdog()
        {
            try
            {
                var info = new ProcessStartInfo(App.ExePath, "--watchdog " + Process.GetCurrentProcess().Id)
                {
                    UseShellExecute = false,
                    CreateNoWindow = true
                };
                Process.Start(info);
            }
            catch (Exception) { }
        }

        private void Tick()
        {
            ticks++;
            if (session == null)
            {
                if (ticks % 30 == 0) power = Power.Snapshot();
                return;
            }
            if (session.Ends.HasValue && DateTime.Now >= session.Ends.Value)
            {
                bool closed = lid.LidClosed == true && lidApplied;
                End(StopReason.TimeUp);
                if (closed) Power.Sleep();
                return;
            }
            if (ticks % 5 == 0)
            {
                var expired = agentHolds.Where(h => h.Value <= DateTime.UtcNow).Select(h => h.Key).ToList();
                foreach (var id in expired) agentHolds.Remove(id);
                if (expired.Count > 0)
                {
                    EndAgentSessionIfIdle(StopReason.AgentsQuiet);
                    if (session == null) return;
                }

                power = Power.Snapshot();
                var violation = Rules.SessionViolation(power, Settings.RequireCharger, Settings.EndOnLowBattery, Settings.BatteryCutoff);
                if (violation != StopReason.None)
                {
                    bool closed = lid.LidClosed == true && lidApplied;
                    End(violation);
                    if (closed) Power.Sleep();
                    return;
                }
                if (lidApplied && lid.LidClosed == true && lid.ClosedSince.HasValue)
                {
                    var lidViolation = Rules.ClosedLidViolation(power, Settings.RequireCharger, Settings.EndOnLowBattery,
                        Settings.BatteryCutoff, Settings.ClosedLimitMinutes, DateTime.UtcNow - lid.ClosedSince.Value);
                    if (lidViolation != StopReason.None)
                    {
                        End(lidViolation);
                        Power.Sleep();
                        return;
                    }
                }
                SyncLid();
            }
            UpdateTray();
        }

        private void OnLidChanged() => UpdateTray();

        private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
        {
            if (e.Mode == PowerModes.Suspend)
                ui.Post(_ => End(StopReason.SystemSleep), null);
        }

        // MARK: Tray and menu

        private void UpdateTray()
        {
            var icon = session != null ? activeIcon : idleIcon;
            if (tray.Icon != icon) tray.Icon = icon;
            string text;
            if (session == null) text = "Lidless: idle";
            else if (session.Ends.HasValue) text = "Lidless: " + Rules.Clock(session.Ends.Value - DateTime.Now) + " left";
            else if (session.StartedByAgents) text = "Lidless: Claude Code is working";
            else text = "Lidless: on until you stop it";
            if (text.Length > 63) text = text.Substring(0, 63);
            if (tray.Text != text) tray.Text = text;
        }

        private void ShowMenu()
        {
            // NotifyIcon only exposes the context menu through this private method.
            var method = typeof(NotifyIcon).GetMethod("ShowContextMenu",
                System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
            method?.Invoke(tray, null);
        }

        private void BuildMenu()
        {
            power = Power.Snapshot();
            while (menu.Items.Count > 0) menu.Items[0].Dispose();

            menu.Items.Add(new ToolStripMenuItem(StatusLine()) { Enabled = false });
            string lidLine = LidLine();
            if (lidLine != null) menu.Items.Add(new ToolStripMenuItem(lidLine) { Enabled = false });
            menu.Items.Add(new ToolStripSeparator());

            if (session == null)
            {
                foreach (int minutes in TimerPresets)
                {
                    int value = minutes;
                    menu.Items.Add(new ToolStripMenuItem("Start for " + Rules.Words(value), null,
                        (s, e) => Start(DateTime.Now.AddMinutes(value), null, false)));
                }
                var until = new ToolStripMenuItem("Start until");
                var hour = DateTime.Now.Date.AddHours(DateTime.Now.Hour + 1);
                for (int i = 0; i < 12; i++)
                {
                    var target = hour.AddHours(i);
                    string label = target.ToString("HH:mm") + (target.Date > DateTime.Now.Date ? " tomorrow" : "");
                    until.DropDownItems.Add(new ToolStripMenuItem(label, null, (s, e) => Start(target, null, false)));
                }
                menu.Items.Add(until);
                menu.Items.Add(new ToolStripMenuItem("Start without a limit", null, (s, e) => Start(null, null, false)));
            }
            else
            {
                if (session.Ends.HasValue)
                    menu.Items.Add(new ToolStripMenuItem("+15 min", null, (s, e) => Extend(15)));
                menu.Items.Add(new ToolStripMenuItem("Stop", null, (s, e) => { agentHolds.Clear(); End(StopReason.None); })
                {
                    Font = boldFont ?? (boldFont = new Font(menu.Font, FontStyle.Bold))
                });
            }

            if (power.HasBattery)
            {
                menu.Items.Add(new ToolStripSeparator());
                menu.Items.Add(Check("Keep running with the lid closed", Settings.ClosedLidEnabled, v =>
                {
                    Settings.ClosedLidEnabled = v;
                    SyncLid();
                }));
                var limits = new ToolStripMenuItem("While closed");
                foreach (int minutes in ClosedLimits)
                {
                    int value = minutes;
                    limits.DropDownItems.Add(new ToolStripMenuItem(value == 0 ? "Whole session" : Rules.Words(value), null,
                        (s, e) => Settings.ClosedLimitMinutes = value)
                    { Checked = Settings.ClosedLimitMinutes == value });
                }
                limits.Enabled = Settings.ClosedLidEnabled;
                menu.Items.Add(limits);

                menu.Items.Add(new ToolStripSeparator());
                menu.Items.Add(new ToolStripMenuItem(PowerLine()) { Enabled = false });
                menu.Items.Add(Check("Require charger", Settings.RequireCharger, v => Settings.RequireCharger = v));
                menu.Items.Add(Check("End on low battery", Settings.EndOnLowBattery, v => Settings.EndOnLowBattery = v));
                var cutoff = new ToolStripMenuItem($"Stop at {Settings.BatteryCutoff}%");
                foreach (int percent in Cutoffs)
                {
                    int value = percent;
                    cutoff.DropDownItems.Add(new ToolStripMenuItem(value + "%", null, (s, e) => Settings.BatteryCutoff = value)
                    { Checked = Settings.BatteryCutoff == value });
                }
                cutoff.Enabled = Settings.EndOnLowBattery;
                menu.Items.Add(cutoff);
            }

            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(Check("Keep the display on", Settings.KeepDisplayOn, v =>
            {
                Settings.KeepDisplayOn = v;
                if (session != null) Power.KeepAwake(v);
            }));
            menu.Items.Add(Check("Keep awake while Claude Code works", ClaudeHooks.IsInstalled(), v =>
            {
                try
                {
                    if (v) ClaudeHooks.Install(HookExePath); else ClaudeHooks.Uninstall();
                }
                catch (Exception ex)
                {
                    Notify("Could not update Claude Code settings: " + ex.Message);
                }
            }));
            menu.Items.Add(Check("Start with Windows", Settings.StartWithWindows, v => Settings.StartWithWindows = v));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("Quit Lidless  (v" + App.Version + ")", null, (s, e) => Quit()));
        }

        private string StatusLine()
        {
            if (session == null) return "Idle";
            if (session.StartedByAgents)
                return agentHolds.Count > 1 ? $"Claude Code: {agentHolds.Count} sessions working" : "Claude Code is working";
            if (session.Ends.HasValue)
                return "Keeping awake, " + Rules.Clock(session.Ends.Value - DateTime.Now) + " left (until " + session.Ends.Value.ToString("HH:mm") + ")";
            return "Keeping awake until you stop it";
        }

        private string LidLine()
        {
            if (!power.HasBattery || !ClosedLidActive) return null;
            if (lidError != null) return lidError;
            if (session == null) return "Lid: start a session, then close the lid";
            if (lidApplied) return "Ready to close the lid";
            return "Lid: preparing, keep it open";
        }

        private string PowerLine()
        {
            string percent = power.BatteryPercent >= 0 ? power.BatteryPercent + "%" : "";
            switch (power.Source)
            {
                case PowerSource.Adapter: return "Power: charger, " + percent;
                case PowerSource.Battery: return "Power: battery, " + percent;
                default: return "Power: unknown";
            }
        }

        private static ToolStripMenuItem Check(string text, bool value, Action<bool> onChange)
        {
            var item = new ToolStripMenuItem(text) { Checked = value, CheckOnClick = true };
            item.CheckedChanged += (s, e) => onChange(item.Checked);
            return item;
        }

        private void Notify(string message)
        {
            tray.BalloonTipTitle = "Lidless";
            tray.BalloonTipText = message;
            tray.ShowBalloonTip(4000);
        }

        private void Quit()
        {
            End(StopReason.None);
            ExitThread();
        }

        protected override void ExitThreadCore()
        {
            ticker.Stop();
            SystemEvents.PowerModeChanged -= OnPowerModeChanged;
            Power.AllowSleep();
            Power.Restore();
            lid.Dispose();
            tray.Visible = false;
            tray.Dispose();
            base.ExitThreadCore();
        }
    }
}
