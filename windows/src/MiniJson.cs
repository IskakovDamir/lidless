using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace Lidless
{
    /// <summary>A JSON object that keeps its key order, so rewriting a user's file changes as little as possible.</summary>
    public sealed class JsonObject
    {
        private readonly List<string> keys = new List<string>();
        private readonly Dictionary<string, object> values = new Dictionary<string, object>();

        public IEnumerable<string> Keys => keys;
        public int Count => keys.Count;

        public object this[string key]
        {
            get { return values.TryGetValue(key, out var value) ? value : null; }
            set
            {
                if (!values.ContainsKey(key)) keys.Add(key);
                values[key] = value;
            }
        }

        public bool ContainsKey(string key) => values.ContainsKey(key);

        public void Remove(string key)
        {
            if (values.Remove(key)) keys.Remove(key);
        }
    }

    /// <summary>A number kept as its original text.</summary>
    public sealed class JsonNumber
    {
        public readonly string Raw;
        public JsonNumber(string raw) { Raw = raw; }
        public JsonNumber(int value) { Raw = value.ToString(CultureInfo.InvariantCulture); }
    }

    /// <summary>Small JSON reader and pretty writer. Objects are JsonObject, arrays List&lt;object&gt;,
    /// strings string, numbers JsonNumber, true/false bool, null null.</summary>
    public static class MiniJson
    {
        public static object Parse(string text)
        {
            int i = 0;
            object value = ReadValue(text, ref i);
            SkipSpace(text, ref i);
            if (i != text.Length) throw new FormatException("Trailing characters at " + i);
            return value;
        }

        public static string Write(object value)
        {
            var sb = new StringBuilder();
            WriteValue(sb, value, 0);
            sb.Append('\n');
            return sb.ToString();
        }

        // MARK: reading

        private static void SkipSpace(string s, ref int i)
        {
            while (i < s.Length && char.IsWhiteSpace(s[i])) i++;
        }

        private static object ReadValue(string s, ref int i)
        {
            SkipSpace(s, ref i);
            if (i >= s.Length) throw new FormatException("Unexpected end");
            char c = s[i];
            if (c == '{') return ReadObject(s, ref i);
            if (c == '[') return ReadArray(s, ref i);
            if (c == '"') return ReadString(s, ref i);
            if (Match(s, ref i, "true")) return true;
            if (Match(s, ref i, "false")) return false;
            if (Match(s, ref i, "null")) return null;
            if (c == '-' || char.IsDigit(c)) return ReadNumber(s, ref i);
            throw new FormatException("Unexpected character at " + i);
        }

        private static bool Match(string s, ref int i, string word)
        {
            if (string.CompareOrdinal(s, i, word, 0, word.Length) != 0) return false;
            i += word.Length;
            return true;
        }

        private static JsonObject ReadObject(string s, ref int i)
        {
            var obj = new JsonObject();
            i++; // {
            SkipSpace(s, ref i);
            if (i < s.Length && s[i] == '}') { i++; return obj; }
            while (true)
            {
                SkipSpace(s, ref i);
                if (i >= s.Length || s[i] != '"') throw new FormatException("Expected key at " + i);
                string key = ReadString(s, ref i);
                SkipSpace(s, ref i);
                if (i >= s.Length || s[i] != ':') throw new FormatException("Expected ':' at " + i);
                i++;
                obj[key] = ReadValue(s, ref i);
                SkipSpace(s, ref i);
                if (i < s.Length && s[i] == ',') { i++; continue; }
                if (i < s.Length && s[i] == '}') { i++; return obj; }
                throw new FormatException("Expected ',' or '}' at " + i);
            }
        }

        private static List<object> ReadArray(string s, ref int i)
        {
            var list = new List<object>();
            i++; // [
            SkipSpace(s, ref i);
            if (i < s.Length && s[i] == ']') { i++; return list; }
            while (true)
            {
                list.Add(ReadValue(s, ref i));
                SkipSpace(s, ref i);
                if (i < s.Length && s[i] == ',') { i++; continue; }
                if (i < s.Length && s[i] == ']') { i++; return list; }
                throw new FormatException("Expected ',' or ']' at " + i);
            }
        }

        private static string ReadString(string s, ref int i)
        {
            var sb = new StringBuilder();
            i++; // opening quote
            while (i < s.Length)
            {
                char c = s[i++];
                if (c == '"') return sb.ToString();
                if (c != '\\') { sb.Append(c); continue; }
                if (i >= s.Length) break;
                char e = s[i++];
                switch (e)
                {
                    case '"': sb.Append('"'); break;
                    case '\\': sb.Append('\\'); break;
                    case '/': sb.Append('/'); break;
                    case 'b': sb.Append('\b'); break;
                    case 'f': sb.Append('\f'); break;
                    case 'n': sb.Append('\n'); break;
                    case 'r': sb.Append('\r'); break;
                    case 't': sb.Append('\t'); break;
                    case 'u':
                        if (i + 4 > s.Length) throw new FormatException("Bad \\u escape");
                        sb.Append((char)int.Parse(s.Substring(i, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture));
                        i += 4;
                        break;
                    default: throw new FormatException("Bad escape at " + i);
                }
            }
            throw new FormatException("Unterminated string");
        }

        private static JsonNumber ReadNumber(string s, ref int i)
        {
            int start = i;
            while (i < s.Length && "+-0123456789.eE".IndexOf(s[i]) >= 0) i++;
            return new JsonNumber(s.Substring(start, i - start));
        }

        // MARK: writing

        private static void WriteValue(StringBuilder sb, object value, int depth)
        {
            switch (value)
            {
                case null: sb.Append("null"); break;
                case bool b: sb.Append(b ? "true" : "false"); break;
                case string str: WriteString(sb, str); break;
                case JsonNumber n: sb.Append(n.Raw); break;
                case int n: sb.Append(n.ToString(CultureInfo.InvariantCulture)); break;
                case JsonObject obj: WriteObject(sb, obj, depth); break;
                case List<object> list: WriteArray(sb, list, depth); break;
                default: WriteString(sb, Convert.ToString(value, CultureInfo.InvariantCulture)); break;
            }
        }

        private static void Indent(StringBuilder sb, int depth) => sb.Append(' ', depth * 2);

        private static void WriteObject(StringBuilder sb, JsonObject obj, int depth)
        {
            if (obj.Count == 0) { sb.Append("{}"); return; }
            sb.Append("{\n");
            int index = 0;
            foreach (string key in obj.Keys)
            {
                Indent(sb, depth + 1);
                WriteString(sb, key);
                sb.Append(": ");
                WriteValue(sb, obj[key], depth + 1);
                if (++index < obj.Count) sb.Append(',');
                sb.Append('\n');
            }
            Indent(sb, depth);
            sb.Append('}');
        }

        private static void WriteArray(StringBuilder sb, List<object> list, int depth)
        {
            if (list.Count == 0) { sb.Append("[]"); return; }
            sb.Append("[\n");
            for (int i = 0; i < list.Count; i++)
            {
                Indent(sb, depth + 1);
                WriteValue(sb, list[i], depth + 1);
                if (i < list.Count - 1) sb.Append(',');
                sb.Append('\n');
            }
            Indent(sb, depth);
            sb.Append(']');
        }

        private static void WriteString(StringBuilder sb, string s)
        {
            sb.Append('"');
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    case '\b': sb.Append("\\b"); break;
                    case '\f': sb.Append("\\f"); break;
                    default:
                        if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                        else sb.Append(c);
                        break;
                }
            }
            sb.Append('"');
        }
    }
}
