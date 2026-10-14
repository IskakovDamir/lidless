using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Lidless
{
    /// <summary>Keep-awake requests, battery state and the lid close action.</summary>
    internal static class Power
    {
        /// <summary>Must be called on the UI thread: the request lives as long as that thread.
        /// Shows up in `powercfg /requests`.</summary>
        public static void KeepAwake(bool display)
        {
            uint flags = Native.ES_CONTINUOUS | Native.ES_SYSTEM_REQUIRED;
            if (display) flags |= Native.ES_DISPLAY_REQUIRED;
            Native.SetThreadExecutionState(flags);
        }

        public static void AllowSleep()
        {
            Native.SetThreadExecutionState(Native.ES_CONTINUOUS);
        }

        public static PowerSnapshot Snapshot()
        {
            var status = SystemInformation.PowerStatus;
            bool hasBattery = (status.BatteryChargeStatus & BatteryChargeStatus.NoSystemBattery) == 0
                              && status.BatteryChargeStatus != BatteryChargeStatus.Unknown;
            int percent = -1;
            if (hasBattery && status.BatteryLifePercent >= 0 && status.BatteryLifePercent <= 1)
                percent = (int)Math.Floor(status.BatteryLifePercent * 100);
            PowerSource source;
            switch (status.PowerLineStatus)
            {
                case PowerLineStatus.Online: source = PowerSource.Adapter; break;
                case PowerLineStatus.Offline: source = PowerSource.Battery; break;
                default: source = hasBattery ? PowerSource.Unknown : PowerSource.Adapter; break;
            }
            return new PowerSnapshot(source, percent, hasBattery);
        }

        public static bool Sleep()
        {
            return Application.SetSuspendState(PowerState.Suspend, false, false);
        }

        // MARK: lid close action

        private const string JournalKey = @"Software\Lidless\Journal";

        public static bool HasJournal()
        {
            using (var key = Registry.CurrentUser.OpenSubKey(JournalKey))
                return key?.GetValue("Scheme") != null;
        }

        /// <summary>Sets "When I close the lid" to "Do nothing" on charger and battery, journaling the
        /// previous values first. Returns an error message, or null on success.</summary>
        public static string ApplyLidDoNothing()
        {
            if (HasJournal()) return null; // already applied
            if (!TryActiveScheme(out Guid scheme)) return "Windows did not report the active power plan.";
            Guid sub = Native.SubgroupButtons, setting = Native.LidAction;
            if (Native.PowerReadACValueIndex(IntPtr.Zero, ref scheme, ref sub, ref setting, out uint ac) != 0 ||
                Native.PowerReadDCValueIndex(IntPtr.Zero, ref scheme, ref sub, ref setting, out uint dc) != 0)
                return "Windows did not report the current lid setting.";

            using (var key = Registry.CurrentUser.CreateSubKey(JournalKey))
            {
                key.SetValue("Scheme", scheme.ToString());
                key.SetValue("AC", (int)ac, RegistryValueKind.DWord);
                key.SetValue("DC", (int)dc, RegistryValueKind.DWord);
                key.Flush();
            }
            if (!WriteLidAction(scheme, 0, 0))
            {
                Restore();
                return "Windows refused to change the lid setting. Your account may need admin rights for power settings.";
            }
            return null;
        }

        /// <summary>Puts back the journaled lid action. Safe to call any time.</summary>
        public static bool Restore()
        {
            uint ac, dc;
            Guid scheme;
            using (var key = Registry.CurrentUser.OpenSubKey(JournalKey))
            {
                if (key == null || key.GetValue("Scheme") == null) return true;
                if (!Guid.TryParse(key.GetValue("Scheme") as string, out scheme)) scheme = Guid.Empty;
                ac = (uint)(int)(key.GetValue("AC") ?? 1);
                dc = (uint)(int)(key.GetValue("DC") ?? 1);
            }
            bool ok = scheme == Guid.Empty || WriteLidAction(scheme, ac, dc);
            if (ok) Registry.CurrentUser.DeleteSubKeyTree(JournalKey, false);
            return ok;
        }

        private static bool WriteLidAction(Guid scheme, uint ac, uint dc)
        {
            Guid sub = Native.SubgroupButtons, setting = Native.LidAction;
            if (Native.PowerWriteACValueIndex(IntPtr.Zero, ref scheme, ref sub, ref setting, ac) != 0) return false;
            if (Native.PowerWriteDCValueIndex(IntPtr.Zero, ref scheme, ref sub, ref setting, dc) != 0) return false;
            // Writing to the active plan only takes effect after it is set active again.
            if (TryActiveScheme(out Guid active) && active == scheme)
                Native.PowerSetActiveScheme(IntPtr.Zero, ref scheme);
            return true;
        }

        private static bool TryActiveScheme(out Guid scheme)
        {
            scheme = Guid.Empty;
            if (Native.PowerGetActiveScheme(IntPtr.Zero, out IntPtr pointer) != 0 || pointer == IntPtr.Zero) return false;
            try { scheme = (Guid)Marshal.PtrToStructure(pointer, typeof(Guid)); }
            finally { Native.LocalFree(pointer); }
            return true;
        }
    }
}
