using System;
using System.Collections.Generic;
using Lidless;
using Xunit;

public class RulesTests
{
    private static PowerSnapshot Battery(int percent) => new PowerSnapshot(PowerSource.Battery, percent, true);
    private static PowerSnapshot Charger(int percent = 80) => new PowerSnapshot(PowerSource.Adapter, percent, true);
    private static PowerSnapshot Desktop() => new PowerSnapshot(PowerSource.Adapter, -1, false);

    [Fact]
    public void ChargerRequiredStopsOnBattery()
    {
        Assert.Equal(StopReason.ChargerRequired, Rules.SessionViolation(Battery(90), true, true, 20));
        Assert.Equal(StopReason.None, Rules.SessionViolation(Charger(5), true, true, 20));
    }

    [Fact]
    public void LowBatteryCutoff()
    {
        Assert.Equal(StopReason.None, Rules.SessionViolation(Battery(21), false, true, 20));
        Assert.Equal(StopReason.LowBattery, Rules.SessionViolation(Battery(20), false, true, 20));
        Assert.Equal(StopReason.None, Rules.SessionViolation(Battery(3), false, false, 20));
    }

    [Fact]
    public void DesktopIgnoresBatteryRules()
    {
        Assert.Equal(StopReason.None, Rules.SessionViolation(Desktop(), true, true, 20));
        Assert.Equal(StopReason.None, Rules.ClosedLidViolation(Desktop(), true, true, 20, 0, TimeSpan.Zero));
    }

    [Fact]
    public void ClosedLidFloorAndLimit()
    {
        // Without a cutoff the floor still applies.
        Assert.Equal(StopReason.LowBattery, Rules.ClosedLidViolation(Battery(9), false, false, 20, 0, TimeSpan.Zero));
        Assert.Equal(StopReason.None, Rules.ClosedLidViolation(Battery(11), false, false, 20, 0, TimeSpan.Zero));
        Assert.Equal(StopReason.None, Rules.ClosedLidViolation(Charger(), true, true, 20, 30, TimeSpan.FromMinutes(29)));
        Assert.Equal(StopReason.ClosedLimitReached, Rules.ClosedLidViolation(Charger(), true, true, 20, 30, TimeSpan.FromMinutes(30)));
        Assert.Equal(StopReason.None, Rules.ClosedLidViolation(Charger(), true, true, 20, 0, TimeSpan.FromHours(20)));
    }

    [Fact]
    public void Formatting()
    {
        Assert.Equal("1:02:05", Rules.Clock(TimeSpan.FromSeconds(3725)));
        Assert.Equal("1:05", Rules.Clock(TimeSpan.FromSeconds(65)));
        Assert.Equal("2 h 30 min", Rules.Words(150));
        Assert.Equal("1 h", Rules.Words(60));
        Assert.Equal("45 min", Rules.Words(45));
    }

    [Fact]
    public void SanitizeId()
    {
        Assert.Equal("abc-1_2", Rules.SanitizeId("abc-1_2"));
        Assert.Equal("abc", Rules.SanitizeId("a\"b;c"));
        Assert.Null(Rules.SanitizeId("\"';"));
        Assert.Equal(64, Rules.SanitizeId(new string('x', 100)).Length);
    }
}

public class JsonAndHooksTests
{
    private const string UserSettings = @"{
  ""model"": ""opus"",
  ""permissions"": { ""allow"": [""Bash(ls:*)""] },
  ""hooks"": {
    ""Stop"": [
      { ""hooks"": [ { ""type"": ""command"", ""command"": ""say done"" } ] }
    ]
  },
  ""ratio"": 1.50
}";

    [Fact]
    public void RoundTripKeepsOrderAndNumbers()
    {
        var obj = (JsonObject)MiniJson.Parse(UserSettings);
        var again = (JsonObject)MiniJson.Parse(MiniJson.Write(obj));
        Assert.Equal(new List<string> { "model", "permissions", "hooks", "ratio" }, new List<string>(again.Keys));
        Assert.Equal("1.50", ((JsonNumber)again["ratio"]).Raw);
    }

    [Fact]
    public void ApplyAddsHooksAndKeepsUserOnes()
    {
        var settings = (JsonObject)MiniJson.Parse(UserSettings);
        ClaudeHooks.Apply(settings, @"C:\Users\damir\AppData\Local\Lidless\Lidless.exe");
        var hooks = (JsonObject)settings["hooks"];
        Assert.True(hooks.ContainsKey("UserPromptSubmit"));
        Assert.True(hooks.ContainsKey("PostToolUse"));
        Assert.True(hooks.ContainsKey("SessionEnd"));
        var stop = (List<object>)hooks["Stop"];
        Assert.Equal(2, stop.Count); // user's own hook plus ours
        string text = MiniJson.Write(settings);
        Assert.Contains("C:/Users/damir/AppData/Local/Lidless/Lidless.exe hook hold", text);
        Assert.Contains("say done", text);
        Assert.Equal("opus", settings["model"]);
    }

    [Fact]
    public void ApplyIsIdempotent()
    {
        var settings = (JsonObject)MiniJson.Parse(UserSettings);
        ClaudeHooks.Apply(settings, @"C:\Tools\Lidless.exe");
        ClaudeHooks.Apply(settings, @"C:\Tools\Lidless.exe");
        var hooks = (JsonObject)settings["hooks"];
        Assert.Single((List<object>)hooks["UserPromptSubmit"]);
        Assert.Equal(2, ((List<object>)hooks["Stop"]).Count);
    }

    [Fact]
    public void PathWithSpacesIsQuoted()
    {
        Assert.Equal("\"C:/Users/Damir Iskakov/Lidless.exe\" hook hold",
                     ClaudeHooks.CommandFor(@"C:\Users\Damir Iskakov\Lidless.exe", "hold"));
        Assert.Equal("C:/Tools/Lidless.exe hook release", ClaudeHooks.CommandFor(@"C:\Tools\Lidless.exe", "release"));
    }

    [Fact]
    public void RemoveRestoresOriginalShape()
    {
        var settings = (JsonObject)MiniJson.Parse(UserSettings);
        ClaudeHooks.Apply(settings, @"C:\Tools\Lidless.exe");
        ClaudeHooks.Remove(settings);
        Assert.Equal(MiniJson.Write((JsonObject)MiniJson.Parse(UserSettings)), MiniJson.Write(settings));
    }

    [Fact]
    public void RemoveDropsEmptyHooksObject()
    {
        var settings = new JsonObject();
        ClaudeHooks.Apply(settings, @"C:\Tools\Lidless.exe");
        ClaudeHooks.Remove(settings);
        Assert.False(settings.ContainsKey("hooks"));
    }

    [Fact]
    public void ParsesEscapes()
    {
        var obj = (JsonObject)MiniJson.Parse("{\"a\":\"line\\nquote\\\" \\u00e9\",\"b\":[true,false,null,-3]}");
        Assert.Equal("line\nquote\" é", obj["a"]);
        var list = (List<object>)obj["b"];
        Assert.Equal(true, list[0]);
        Assert.Null(list[2]);
        Assert.Equal("-3", ((JsonNumber)list[3]).Raw);
    }
}
