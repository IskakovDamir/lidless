using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace Lidless
{
    /// <summary>Adds or removes Lidless hooks in %USERPROFILE%\.claude\settings.json,
    /// leaving every other setting untouched.</summary>
    public static class ClaudeHooks
    {
        public const string Marker = "Lidless.exe";

        private static readonly string[][] Events =
        {
            new[] { "UserPromptSubmit", "hold", null },
            new[] { "PostToolUse", "refresh", "*" },
            new[] { "Stop", "release", null },
            new[] { "SessionEnd", "release", null },
        };

        public static string SettingsPath =>
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "settings.json");

        public static bool IsInstalled(string exePath = null)
        {
            try
            {
                var settings = Load();
                if (!(settings["hooks"] is JsonObject hooks)) return false;
                if (exePath == null) return ContainsMarker(hooks);
                return ContainsText(hooks, CommandFor(exePath, "hold"));
            }
            catch { return false; }
        }

        public static void Install(string exePath)
        {
            var settings = Load();
            Apply(settings, exePath);
            Save(settings);
        }

        public static void Uninstall()
        {
            var settings = Load();
            Remove(settings);
            Save(settings);
        }

        // MARK: pure transforms (unit tested)

        public static void Apply(JsonObject settings, string exePath)
        {
            Remove(settings);
            var hooks = settings["hooks"] as JsonObject ?? new JsonObject();
            foreach (var e in Events)
            {
                var handler = new JsonObject();
                handler["type"] = "command";
                handler["command"] = CommandFor(exePath, e[1]);
                handler["timeout"] = new JsonNumber(10);

                var group = new JsonObject();
                if (e[2] != null) group["matcher"] = e[2];
                group["hooks"] = new List<object> { handler };

                var groups = hooks[e[0]] as List<object> ?? new List<object>();
                groups.Add(group);
                hooks[e[0]] = groups;
            }
            settings["hooks"] = hooks;
        }

        public static void Remove(JsonObject settings)
        {
            if (!(settings["hooks"] is JsonObject hooks)) return;
            foreach (string evt in new List<string>(hooks.Keys))
            {
                if (!(hooks[evt] is List<object> groups)) continue;
                var kept = new List<object>();
                foreach (object item in groups)
                {
                    if (item is JsonObject group && group["hooks"] is List<object> handlers)
                    {
                        var remaining = handlers.FindAll(h => !ContainsMarker(h));
                        if (remaining.Count == 0) continue;
                        group["hooks"] = remaining;
                        kept.Add(group);
                    }
                    else
                    {
                        kept.Add(item);
                    }
                }
                if (kept.Count == 0) hooks.Remove(evt); else hooks[evt] = kept;
            }
            if (hooks.Count == 0) settings.Remove("hooks");
        }

        /// <summary>Forward slashes and no quotes run the same in Git Bash and PowerShell, so callers pass a
        /// path without spaces (the app uses the 8.3 short path). A path that still has spaces is quoted,
        /// which works in Git Bash, the default hook shell on Windows.</summary>
        public static string CommandFor(string exePath, string action)
        {
            string path = ToForwardSlashes(exePath);
            if (path.Contains(" ")) path = "\"" + path + "\"";
            return path + " hook " + action;
        }

        private static string ToForwardSlashes(string path) => path.Replace('\\', '/');

        private static bool ContainsMarker(object value) => ContainsText(value, Marker);

        private static bool ContainsText(object value, string text)
        {
            switch (value)
            {
                case string s: return s.IndexOf(text, StringComparison.OrdinalIgnoreCase) >= 0;
                case List<object> list: return list.Exists(v => ContainsText(v, text));
                case JsonObject obj:
                    foreach (string key in obj.Keys) if (ContainsText(obj[key], text)) return true;
                    return false;
                default: return false;
            }
        }

        // MARK: file IO

        private static JsonObject Load()
        {
            if (!File.Exists(SettingsPath)) return new JsonObject();
            string text = File.ReadAllText(SettingsPath, Encoding.UTF8);
            if (string.IsNullOrWhiteSpace(text)) return new JsonObject();
            if (!(MiniJson.Parse(text) is JsonObject obj))
                throw new InvalidDataException("settings.json does not contain a JSON object, so it was left as is.");
            return obj;
        }

        private static void Save(JsonObject settings)
        {
            string dir = Path.GetDirectoryName(SettingsPath);
            Directory.CreateDirectory(dir);
            string backup = SettingsPath + ".lidless-backup";
            if (File.Exists(SettingsPath) && !File.Exists(backup)) File.Copy(SettingsPath, backup);
            string temp = SettingsPath + ".lidless-tmp";
            File.WriteAllText(temp, MiniJson.Write(settings), new UTF8Encoding(false));
            if (File.Exists(SettingsPath)) File.Replace(temp, SettingsPath, null);
            else File.Move(temp, SettingsPath);
        }
    }
}
