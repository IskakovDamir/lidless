using System;

namespace Lidless
{
    public enum PowerSource { Adapter, Battery, Unknown }

    public sealed class PowerSnapshot
    {
        public PowerSource Source;
        /// <summary>0..100, or -1 when unknown or there is no battery.</summary>
        public int BatteryPercent = -1;
        public bool HasBattery;

        public PowerSnapshot(PowerSource source, int batteryPercent, bool hasBattery)
        {
            Source = source;
            BatteryPercent = batteryPercent;
            HasBattery = hasBattery;
        }
    }

    public enum StopReason
    {
        None,
        TimeUp,
        ChargerRequired,
        LowBattery,
        ClosedLimitReached,
        PowerUnknown,
        AgentsFinished,
        AgentsQuiet,
        SystemSleep
    }

    /// <summary>Pure decision logic shared by the app and the unit tests.</summary>
    public static class Rules
    {
        /// <summary>With the lid closed on battery, Lidless always stops at this charge.</summary>
        public const int BatteryFloor = 10;

        /// <summary>Rules for every session, lid open or closed.</summary>
        public static StopReason SessionViolation(PowerSnapshot power, bool requireCharger, bool endOnLowBattery, int cutoff)
        {
            if (!power.HasBattery || power.Source != PowerSource.Battery) return StopReason.None;
            if (requireCharger) return StopReason.ChargerRequired;
            if (endOnLowBattery && power.BatteryPercent >= 0 && power.BatteryPercent <= cutoff) return StopReason.LowBattery;
            return StopReason.None;
        }

        /// <summary>Extra rules while the lid is closed.</summary>
        public static StopReason ClosedLidViolation(PowerSnapshot power, bool requireCharger, bool endOnLowBattery,
                                                    int cutoff, int closedLimitMinutes, TimeSpan closedFor)
        {
            if (power.HasBattery)
            {
                if (power.Source == PowerSource.Unknown) return StopReason.PowerUnknown;
                if (power.Source == PowerSource.Battery)
                {
                    if (requireCharger) return StopReason.ChargerRequired;
                    if (power.BatteryPercent < 0) return StopReason.PowerUnknown;
                    int effective = Math.Max(endOnLowBattery ? cutoff : 0, BatteryFloor);
                    if (power.BatteryPercent <= effective) return StopReason.LowBattery;
                }
            }
            if (closedLimitMinutes > 0 && closedFor.TotalMinutes >= closedLimitMinutes) return StopReason.ClosedLimitReached;
            return StopReason.None;
        }

        public static string Message(StopReason reason, int cutoff)
        {
            switch (reason)
            {
                case StopReason.TimeUp: return "Time is up, session ended.";
                case StopReason.ChargerRequired: return "Charger disconnected, session ended.";
                case StopReason.LowBattery: return "Battery reached the cutoff, session ended.";
                case StopReason.ClosedLimitReached: return "Closed-lid time limit reached. The PC went to sleep.";
                case StopReason.PowerUnknown: return "Power status is unavailable, session ended.";
                case StopReason.AgentsFinished: return "Claude Code finished, session ended.";
                case StopReason.AgentsQuiet: return "Claude Code went quiet, session ended.";
                case StopReason.SystemSleep: return "The PC went to sleep, session ended.";
                default: return "";
            }
        }

        /// <summary>"1:42:05" or "42:05".</summary>
        public static string Clock(TimeSpan span)
        {
            int total = Math.Max(0, (int)Math.Ceiling(span.TotalSeconds));
            int h = total / 3600, m = total % 3600 / 60, s = total % 60;
            return h > 0 ? $"{h}:{m:00}:{s:00}" : $"{m}:{s:00}";
        }

        /// <summary>"2 h 30 min", "45 min", "1 h".</summary>
        public static string Words(int minutes)
        {
            int h = minutes / 60, m = minutes % 60;
            if (h == 0) return $"{m} min";
            if (m == 0) return $"{h} h";
            return $"{h} h {m} min";
        }

        /// <summary>Keeps letters, digits, '-' and '_', up to 64 characters. Null when nothing is left.</summary>
        public static string SanitizeId(string raw)
        {
            if (string.IsNullOrEmpty(raw)) return null;
            var chars = new System.Text.StringBuilder();
            foreach (char c in raw)
            {
                if (chars.Length >= 64) break;
                if (char.IsLetterOrDigit(c) || c == '-' || c == '_') chars.Append(c);
            }
            return chars.Length == 0 ? null : chars.ToString();
        }
    }
}
