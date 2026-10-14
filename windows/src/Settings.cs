using System;
using Microsoft.Win32;

namespace Lidless
{
    /// <summary>User settings in HKCU\Software\Lidless.</summary>
    internal static class Settings
    {
        private const string KeyPath = @"Software\Lidless";

        public static bool ClosedLidEnabled { get => GetBool(nameof(ClosedLidEnabled), false); set => SetBool(nameof(ClosedLidEnabled), value); }
        public static int ClosedLimitMinutes { get => GetInt(nameof(ClosedLimitMinutes), 120); set => SetInt(nameof(ClosedLimitMinutes), value); }
        public static bool RequireCharger { get => GetBool(nameof(RequireCharger), true); set => SetBool(nameof(RequireCharger), value); }
        public static bool EndOnLowBattery { get => GetBool(nameof(EndOnLowBattery), true); set => SetBool(nameof(EndOnLowBattery), value); }
        public static int BatteryCutoff { get => GetInt(nameof(BatteryCutoff), 20); set => SetInt(nameof(BatteryCutoff), value); }
        public static bool KeepDisplayOn { get => GetBool(nameof(KeepDisplayOn), false); set => SetBool(nameof(KeepDisplayOn), value); }

        private static bool GetBool(string name, bool fallback) => GetInt(name, fallback ? 1 : 0) != 0;
        private static void SetBool(string name, bool value) => SetInt(name, value ? 1 : 0);

        private static int GetInt(string name, int fallback)
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(KeyPath))
                    return key?.GetValue(name) is int value ? value : fallback;
            }
            catch { return fallback; }
        }

        private static void SetInt(string name, int value)
        {
            try
            {
                using (var key = Registry.CurrentUser.CreateSubKey(KeyPath))
                    key.SetValue(name, value, RegistryValueKind.DWord);
            }
            catch { }
        }

        // MARK: integration with Windows

        private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

        public static bool StartWithWindows
        {
            get
            {
                using (var key = Registry.CurrentUser.OpenSubKey(RunKey))
                    return key?.GetValue("Lidless") != null;
            }
            set
            {
                using (var key = Registry.CurrentUser.CreateSubKey(RunKey))
                {
                    if (value) key.SetValue("Lidless", "\"" + App.ExePath + "\"");
                    else key.DeleteValue("Lidless", false);
                }
            }
        }

        /// <summary>Registers lidless:// for the current user. No admin rights needed.</summary>
        public static void RegisterUrlScheme()
        {
            try
            {
                using (var key = Registry.CurrentUser.CreateSubKey(@"Software\Classes\lidless"))
                {
                    key.SetValue("", "URL:Lidless");
                    key.SetValue("URL Protocol", "");
                    using (var command = key.CreateSubKey(@"shell\open\command"))
                        command.SetValue("", "\"" + App.ExePath + "\" \"%1\"");
                }
            }
            catch { }
        }

        /// <summary>Keeps the Run entry pointing at the current exe if the user moved it.</summary>
        public static void RefreshStartWithWindows()
        {
            try { if (StartWithWindows) StartWithWindows = true; } catch { }
        }
    }
}
