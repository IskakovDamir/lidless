using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Lidless
{
    /// <summary>Hidden window that receives lid open/close notifications.</summary>
    internal sealed class LidWatcher : NativeWindow, IDisposable
    {
        private IntPtr registration = IntPtr.Zero;

        /// <summary>True when the lid is closed. Null until Windows reports it (desktops never do).</summary>
        public bool? LidClosed { get; private set; }
        public DateTime? ClosedSince { get; private set; }
        public event Action Changed;

        public LidWatcher()
        {
            CreateHandle(new CreateParams());
            Guid guid = Native.LidSwitchStateChange;
            registration = Native.RegisterPowerSettingNotification(Handle, ref guid, Native.DEVICE_NOTIFY_WINDOW_HANDLE);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Native.WM_POWERBROADCAST && m.WParam.ToInt64() == Native.PBT_POWERSETTINGCHANGE && m.LParam != IntPtr.Zero)
            {
                var setting = (Native.POWERBROADCAST_SETTING)Marshal.PtrToStructure(m.LParam, typeof(Native.POWERBROADCAST_SETTING));
                if (setting.PowerSetting == Native.LidSwitchStateChange && setting.DataLength >= 1)
                {
                    bool closed = setting.Data == 0;
                    if (closed && LidClosed != true) ClosedSince = DateTime.UtcNow;
                    if (!closed) ClosedSince = null;
                    LidClosed = closed;
                    Changed?.Invoke();
                }
            }
            base.WndProc(ref m);
        }

        public void Dispose()
        {
            if (registration != IntPtr.Zero)
            {
                Native.UnregisterPowerSettingNotification(registration);
                registration = IntPtr.Zero;
            }
            DestroyHandle();
        }
    }
}
