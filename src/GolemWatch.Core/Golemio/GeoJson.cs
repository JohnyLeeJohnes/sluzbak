using System.Globalization;
using System.Text.Json;

namespace GolemWatch.Core.Golemio;

internal sealed class FeatureCollection<T> where T : class
{
    public List<Feature<T>>? Features { get; init; }

    /// <summary>Maps the features that carry both properties and a readable position; the rest cannot be placed.</summary>
    public List<TResult> Select<TResult>(Func<T, GeoPoint, TResult?> map) where TResult : class
    {
        var results = new List<TResult>();
        foreach (var feature in Features ?? [])
        {
            if (feature is { Properties: { } properties, Geometry: { } geometry }
                && geometry.ToPoint() is { } point
                && map(properties, point) is { } result)
                results.Add(result);
        }
        return results;
    }
}

internal sealed class Feature<T> where T : class
{
    public Geometry? Geometry { get; init; }
    public T? Properties { get; init; }
}

internal sealed class Geometry
{
    // Kept raw because some endpoints return polygons here.
    public JsonElement Coordinates { get; init; }

    public GeoPoint? ToPoint() => Lenient.Point(Coordinates);
}

/// <summary>
/// Tolerant readers for values the API documents loosely (dates as strings, numbers that may be strings),
/// so one odd field does not fail a whole response.
/// </summary>
internal static class Lenient
{
    /// <summary>Reads a GeoJSON position, which is [longitude, latitude]. Lines and polygons yield their first vertex.</summary>
    public static GeoPoint? Point(JsonElement coordinates)
    {
        while (coordinates.ValueKind == JsonValueKind.Array && coordinates.GetArrayLength() > 0
               && coordinates[0].ValueKind == JsonValueKind.Array)
            coordinates = coordinates[0];

        if (coordinates.ValueKind != JsonValueKind.Array || coordinates.GetArrayLength() < 2
            || coordinates[0].ValueKind != JsonValueKind.Number || coordinates[1].ValueKind != JsonValueKind.Number)
            return null;

        var point = new GeoPoint(coordinates[1].GetDouble(), coordinates[0].GetDouble());
        return point.IsValid ? point : null;
    }

    public static GeoPoint? Point(double? latitude, double? longitude) =>
        latitude is { } lat && longitude is { } lon && new GeoPoint(lat, lon) is { IsValid: true } point ? point : null;

    /// <summary>A value documented as a number in one place and as a code in another.</summary>
    public static string? Text(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.String => value.GetString(),
        JsonValueKind.Number => value.GetRawText(),
        _ => null,
    };

    public static DateTimeOffset? Timestamp(string? text) =>
        DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var value) ? value : null;

    public static DateOnly? Date(string? text)
    {
        if (DateOnly.TryParseExact(text, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date))
            return date;
        return Timestamp(text) is { } timestamp ? DateOnly.FromDateTime(PragueTime.From(timestamp).DateTime) : null;
    }

    public static TimeOnly? Time(string? text) =>
        TimeOnly.TryParse(text, CultureInfo.InvariantCulture, out var value) ? value : null;

    public static int? Rounded(double? value) => value is { } v && double.IsFinite(v) ? (int)Math.Round(v) : null;
}
