using System.Globalization;

namespace SampleBlankSite.Models;

public static class Format
{
    private static readonly string[] Units = ["B", "KB", "MB", "GB", "TB", "PB"];

    public static string Bytes(long? bytes)
    {
        if (bytes is not { } value) return "—";
        double size = value;
        var unit = 0;
        while (size >= 1024 && unit < Units.Length - 1)
        {
            size /= 1024;
            unit++;
        }
        return string.Create(CultureInfo.InvariantCulture, $"{size:0.#} {Units[unit]}");
    }

    public static string Percent(double? value) =>
        value is { } v ? string.Create(CultureInfo.InvariantCulture, $"{v:0.#}%") : "—";

    public static string Number(double? value, string format = "0.00") =>
        value is { } v ? v.ToString(format, CultureInfo.InvariantCulture) : "—";

    public static string Duration(TimeSpan? span)
    {
        if (span is not { } t) return "—";
        if (t.TotalDays >= 1) return $"{(int)t.TotalDays}d {t.Hours}h {t.Minutes}m";
        if (t.TotalHours >= 1) return $"{t.Hours}h {t.Minutes}m";
        if (t.TotalMinutes >= 1) return $"{t.Minutes}m {t.Seconds}s";
        return $"{t.Seconds}s";
    }

    /// <summary>CSS class for a level: ok / info / warn / crit.</summary>
    public static string Css(HealthLevel level) => level switch
    {
        HealthLevel.Critical => "crit",
        HealthLevel.Warn => "warn",
        HealthLevel.Info => "info",
        _ => "ok",
    };

    /// <summary>Level of a usage percentage against warn / critical thresholds.</summary>
    public static HealthLevel Usage(double? percent, double warn = 85, double critical = 95) =>
        percent is not { } p ? HealthLevel.Info
        : p >= critical ? HealthLevel.Critical
        : p >= warn ? HealthLevel.Warn
        : HealthLevel.Ok;
}
