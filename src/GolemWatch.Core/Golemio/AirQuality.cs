using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace GolemWatch.Core.Golemio;

/// <param name="Index">Hourly air quality index; resolve it with <see cref="AirQualityIndexType.Matches"/>.</param>
public sealed record AirQualityStation(
    string Id,
    string Name,
    string? District,
    GeoPoint Location,
    string? Index,
    IReadOnlyList<AirQualityComponent> Components,
    DateTimeOffset? UpdatedAt);

/// <summary>One pollutant averaged over a period; a station reports the same pollutant for several periods.</summary>
/// <param name="Type">Code of an <see cref="AirQualityComponentType"/>, e.g. NO2.</param>
public sealed record AirQualityComponent(string Type, double? Value, int? AveragedHours);

/// <param name="Color">Background colour as RRGGBB, without a leading #.</param>
public sealed record AirQualityIndexType(
    int Id,
    string? Code,
    string? Color,
    string? TextColor,
    string? DescriptionCs,
    string? DescriptionEn)
{
    // The specification gives a station's index as a number but index types are keyed by codes such as "1A",
    // so either may turn up.
    public bool Matches(string? index) =>
        index is not null && (index == Code || index == Id.ToString(CultureInfo.InvariantCulture));
}

public sealed record AirQualityComponentType(string Code, string? Unit, string? DescriptionCs, string? DescriptionEn);

public sealed partial class GolemioClient
{
    /// <summary>ČHMÚ stations, nearest first, optionally only those within <paramref name="rangeMeters"/>.</summary>
    public async Task<IReadOnlyList<AirQualityStation>> GetAirQualityStationsAsync(
        GeoPoint near, int? rangeMeters = null, int? limit = null, CancellationToken ct = default)
    {
        var data = await GetAsync<FeatureCollection<AirQualityStationDto>>("/v2/airqualitystations",
            new Query { { "latlng", near.ToLatLng() }, { "range", rangeMeters }, { "limit", limit } }, ct);

        return data.Select((s, location) => s.Id is null ? null : new AirQualityStation(
            s.Id,
            s.Name ?? s.Id,
            s.District,
            location,
            Lenient.Text(s.Measurement?.AqHourlyIndex ?? default),
            [.. (s.Measurement?.Components ?? [])
                .Where(c => c.Type is not null)
                .Select(c => new AirQualityComponent(c.Type!, c.AveragedTime?.Value, Lenient.Rounded(c.AveragedTime?.AveragedHours)))],
            Lenient.Timestamp(s.UpdatedAt)));
    }

    public async Task<IReadOnlyList<AirQualityIndexType>> GetAirQualityIndexTypesAsync(CancellationToken ct = default)
    {
        var data = await GetAsync<List<AirQualityIndexTypeDto>>("/v2/airqualitystations/indextypes", null, ct);
        return [.. data.Select(t => new AirQualityIndexType(
            Lenient.Rounded(t.Id) ?? 0, t.IndexCode, t.Color, t.ColorText, t.DescriptionCs, t.DescriptionEn))];
    }

    public async Task<IReadOnlyList<AirQualityComponentType>> GetAirQualityComponentTypesAsync(CancellationToken ct = default)
    {
        var data = await GetAsync<List<AirQualityComponentTypeDto>>("/v2/airqualitystations/componenttypes", null, ct);
        return [.. data
            .Where(t => t.ComponentCode is not null)
            .Select(t => new AirQualityComponentType(t.ComponentCode!, t.Unit, t.DescriptionCs, t.DescriptionEn))];
    }
}

file sealed class AirQualityStationDto
{
    public string? Id { get; init; }
    public string? Name { get; init; }
    public string? District { get; init; }
    public AirQualityMeasurementDto? Measurement { get; init; }
    public string? UpdatedAt { get; init; }
}

file sealed class AirQualityMeasurementDto
{
    [JsonPropertyName("AQ_hourly_index")]
    public JsonElement AqHourlyIndex { get; init; }
    public List<AirQualityComponentDto>? Components { get; init; }
}

file sealed class AirQualityComponentDto
{
    public string? Type { get; init; }
    public AveragedTimeDto? AveragedTime { get; init; }
}

file sealed class AveragedTimeDto
{
    public double? AveragedHours { get; init; }
    public double? Value { get; init; }
}

file sealed class AirQualityIndexTypeDto
{
    public double? Id { get; init; }
    public string? IndexCode { get; init; }
    public string? Color { get; init; }
    public string? ColorText { get; init; }
    public string? DescriptionCs { get; init; }
    public string? DescriptionEn { get; init; }
}

file sealed class AirQualityComponentTypeDto
{
    public string? ComponentCode { get; init; }
    public string? Unit { get; init; }
    public string? DescriptionCs { get; init; }
    public string? DescriptionEn { get; init; }
}
