namespace GolemWatch.Core;

/// <summary>The data is about Prague, so times are shown in Prague time whatever the machine is set to.</summary>
public static class PragueTime
{
    private static readonly TimeZoneInfo Zone = TimeZoneInfo.FindSystemTimeZoneById("Europe/Prague");

    public static DateTimeOffset From(DateTimeOffset value) => TimeZoneInfo.ConvertTime(value, Zone);

    public static DateOnly Today(TimeProvider time) => DateOnly.FromDateTime(From(time.GetUtcNow()).DateTime);
}
