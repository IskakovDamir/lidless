using System;
using System.Runtime.InteropServices;

namespace Lidless
{
    internal static class Native
    {
        // SetThreadExecutionState
        public const uint ES_CONTINUOUS = 0x80000000;
        public const uint ES_SYSTEM_REQUIRED = 0x00000001;
        public const uint ES_DISPLAY_REQUIRED = 0x00000002;

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint SetThreadExecutionState(uint flags);

        // Power schemes (powrprof.dll)
        public static readonly Guid SubgroupButtons = new Guid("4f971e89-eebd-4455-a8de-9e59040e7347");
        public static readonly Guid LidAction = new Guid("5ca83367-6e45-459f-a27b-476b1d01c936");
        public static readonly Guid LidSwitchStateChange = new Guid("ba3e0f4d-b817-4094-a2d1-d56379e6a0f3");

        [DllImport("powrprof.dll")]
        public static extern uint PowerGetActiveScheme(IntPtr rootPowerKey, out IntPtr activePolicyGuid);

        [DllImport("powrprof.dll")]
        public static extern uint PowerSetActiveScheme(IntPtr rootPowerKey, ref Guid schemeGuid);

        [DllImport("powrprof.dll")]
        public static extern uint PowerReadACValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid,
            ref Guid subGroupGuid, ref Guid settingGuid, out uint value);

        [DllImport("powrprof.dll")]
        public static extern uint PowerReadDCValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid,
            ref Guid subGroupGuid, ref Guid settingGuid, out uint value);

        [DllImport("powrprof.dll")]
        public static extern uint PowerWriteACValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid,
            ref Guid subGroupGuid, ref Guid settingGuid, uint value);

        [DllImport("powrprof.dll")]
        public static extern uint PowerWriteDCValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid,
            ref Guid subGroupGuid, ref Guid settingGuid, uint value);

        [DllImport("kernel32.dll")]
        public static extern IntPtr LocalFree(IntPtr mem);

        // Lid switch notifications
        public const int WM_POWERBROADCAST = 0x0218;
        public const int PBT_POWERSETTINGCHANGE = 0x8013;
        public const int DEVICE_NOTIFY_WINDOW_HANDLE = 0;

        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr RegisterPowerSettingNotification(IntPtr recipient, ref Guid powerSettingGuid, int flags);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool UnregisterPowerSettingNotification(IntPtr handle);

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        public struct POWERBROADCAST_SETTING
        {
            public Guid PowerSetting;
            public uint DataLength;
            public byte Data;
        }

        [DllImport("user32.dll")]
        public static extern bool DestroyIcon(IntPtr handle);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetShortPathName(string longPath, System.Text.StringBuilder shortPath, uint size);

        /// <summary>The 8.3 form of a path with spaces, so hook commands need no quoting. Falls back to the input.</summary>
        public static string ShortPath(string path)
        {
            if (string.IsNullOrEmpty(path) || !path.Contains(" ")) return path;
            var buffer = new System.Text.StringBuilder(1024);
            uint length = GetShortPathName(path, buffer, (uint)buffer.Capacity);
            return length > 0 && length < buffer.Capacity ? buffer.ToString() : path;
        }
    }
}
