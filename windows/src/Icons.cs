using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Lidless
{
    /// <summary>Draws the tray icon: an eye, crossed out when idle, with a green dot while a session runs.</summary>
    internal static class Icons
    {
        public static Icon Make(bool active)
        {
            int size = SystemInformation.SmallIconSize.Width;
            if (size < 16) size = 16;
            using (var bitmap = new Bitmap(size, size))
            using (var g = Graphics.FromImage(bitmap))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                float s = size / 16f;
                Color ink = TaskbarIsLight() ? Color.FromArgb(30, 30, 30) : Color.White;
                using (var pen = new Pen(ink, 1.4f * s))
                {
                    // Almond outline from two arcs.
                    var path = new GraphicsPath();
                    path.AddBezier(1 * s, 8 * s, 4 * s, 3 * s, 12 * s, 3 * s, 15 * s, 8 * s);
                    path.AddBezier(15 * s, 8 * s, 12 * s, 13 * s, 4 * s, 13 * s, 1 * s, 8 * s);
                    g.DrawPath(pen, path);
                    using (var brush = new SolidBrush(ink))
                        g.FillEllipse(brush, 6 * s, 5.5f * s, 4 * s, 4 * s);
                    if (!active)
                        g.DrawLine(pen, 2.5f * s, 13.5f * s, 13.5f * s, 2.5f * s);
                }
                if (active)
                {
                    using (var dot = new SolidBrush(Color.FromArgb(52, 199, 89)))
                        g.FillEllipse(dot, 10.5f * s, 10.5f * s, 5.5f * s, 5.5f * s);
                }
                IntPtr handle = bitmap.GetHicon();
                try { return (Icon)Icon.FromHandle(handle).Clone(); }
                finally { Native.DestroyIcon(handle); }
            }
        }

        private static bool TaskbarIsLight()
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                    return key?.GetValue("SystemUsesLightTheme") is int value && value == 1;
            }
            catch { return false; }
        }
    }
}
