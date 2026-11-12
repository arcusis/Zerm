using Zerm.Core.Settings;

namespace Zerm.Core.Data;

public sealed record UsageTotals(int Sessions, int Words, int EnhancedSessions, double RecordedSeconds, int ReadAloudWords, int ReadAloudSessions)
{
    public static UsageTotals From(IEnumerable<UsageDay> days)
    {
        var list = days.ToList();
        return new(list.Sum(d => d.Sessions), list.Sum(d => d.Words), list.Sum(d => d.EnhancedSessions),
            list.Sum(d => d.RecordedSeconds), list.Sum(d => d.ReadAloudWords), list.Sum(d => d.ReadAloudSessions));
    }

    public double? WordsPerMinute => RecordedSeconds > 0 ? Words / (RecordedSeconds / 60.0) : null;

    /// <summary>Typing at 35 wpm minus the time spent speaking.</summary>
    public double TimeSavedSeconds => Math.Max(Words / 35.0 * 60 - RecordedSeconds, 0);

    public int KeystrokesSaved => Words * 5;
}

public sealed record UsageBucket(DateTime Start, string Label, int Sessions, int Words, double? Wpm);

public static class UsageMetrics
{
    public static DateTime RangeStart(UsageRange range, DateTime today) => range switch
    {
        UsageRange.Week => today.Date.AddDays(-6),
        UsageRange.Month => today.Date.AddDays(-29),
        UsageRange.Year => new DateTime(today.Year, today.Month, 1).AddMonths(-11),
        _ => DateTime.MinValue,
    };

    public static UsageTotals Totals(IEnumerable<UsageDay> days, UsageRange range, DateTime today)
    {
        var start = RangeStart(range, today);
        return UsageTotals.From(days.Where(d => d.Day >= start && d.Day <= today.Date));
    }

    /// <summary>Daily buckets for 7/30 days, monthly for 12 months and all time; empty buckets are zero-filled.</summary>
    public static List<UsageBucket> Buckets(IReadOnlyList<UsageDay> days, UsageRange range, DateTime today)
    {
        var buckets = new List<UsageBucket>();
        if (range is UsageRange.Week or UsageRange.Month)
        {
            var start = RangeStart(range, today);
            for (var d = start; d <= today.Date; d = d.AddDays(1))
            {
                var t = UsageTotals.From(days.Where(x => x.Day.Date == d));
                buckets.Add(new UsageBucket(d, d.ToString(range == UsageRange.Week ? "ddd" : "M/d"), t.Sessions, t.Words, t.WordsPerMinute));
            }
            return buckets;
        }

        var first = range == UsageRange.Year
            ? RangeStart(range, today)
            : days.Count > 0 ? new DateTime(days.Min(d => d.Day).Year, days.Min(d => d.Day).Month, 1) : new DateTime(today.Year, today.Month, 1);
        for (var m = first; m <= today; m = m.AddMonths(1))
        {
            var t = UsageTotals.From(days.Where(x => x.Day.Year == m.Year && x.Day.Month == m.Month));
            buckets.Add(new UsageBucket(m, m.ToString("MMM yy"), t.Sessions, t.Words, t.WordsPerMinute));
        }
        return buckets;
    }

    /// <summary>Current streak counts back from today (or yesterday if today has no sessions yet).</summary>
    public static (int Current, int Longest) Streaks(IEnumerable<UsageDay> days, DateTime today)
    {
        var active = days.Where(d => d.Sessions > 0).Select(d => d.Day.Date).ToHashSet();
        var cursor = active.Contains(today.Date) ? today.Date : today.Date.AddDays(-1);
        var current = 0;
        while (active.Contains(cursor))
        {
            current++;
            cursor = cursor.AddDays(-1);
        }
        int longest = 0, run = 0;
        DateTime? prev = null;
        foreach (var d in active.OrderBy(d => d))
        {
            run = prev != null && (d - prev.Value).TotalDays == 1 ? run + 1 : 1;
            longest = Math.Max(longest, run);
            prev = d;
        }
        return (current, longest);
    }

    public static string FormatDuration(double seconds)
    {
        var ts = TimeSpan.FromSeconds(Math.Round(seconds));
        if (seconds >= 3600) return $"{(int)ts.TotalHours} hr {ts.Minutes} min";
        if (seconds >= 60) return $"{ts.Minutes} min {ts.Seconds} sec";
        return $"{ts.Seconds} sec";
    }
}
