using System.Text.Json.Serialization;

namespace GolemWatch.Core.Golemio;

/// <summary>Kinds of sorted waste; the values are the API's trash type ids.</summary>
public enum WasteType
{
    Unknown = 0,
    TintedGlass = 1,
    Electric = 2,
    Metals = 3,
    BeverageCartons = 4,
    Paper = 5,
    Plastics = 6,
    ClearGlass = 7,
    EdibleFatsAndOils = 8,
    Multicommodity = 9,
}

/// <summary>A nest of sorted waste containers.</summary>
/// <param name="Accessibility">Who may use it, in Czech: "volně", "obyvatelům domu" or "neznámá dostupnost".</param>
public sealed record WasteStation(
    int Id,
    string Name,
    string? District,
    GeoPoint Location,
    string? Accessibility,
    IReadOnlyList<WasteContainer> Containers);

/// <param name="TypeName">Czech name of the waste type as the API gives it.</param>
/// <param name="PickDays">Collection days in Czech, e.g. "Po, St, So".</param>
/// <param name="FillPercent">Only containers with a sensor report how full they are.</param>
public sealed record WasteContainer(
    int? KsnkoId,
    WasteType Type,
    string? TypeName,
    string? ContainerType,
    string? PickDays,
    DateOnly? NextPick,
    DateTimeOffset? LastPick,
    int? FillPercent,
    DateTimeOffset? MeasuredAt);

/// <summary>A bulky waste container put out for a few hours on one day.</summary>
public sealed record BulkyWasteStation(
    string? Id,
    string? Street,
    string? District,
    GeoPoint Location,
    DateOnly Date,
    TimeOnly? From,
    TimeOnly? To,
    string? ServiceName,
    int? Containers);

public sealed partial class GolemioClient
{
    /// <summary>Sorted waste stations within <paramref name="rangeMeters"/> of a point, nearest first.</summary>
    public async Task<IReadOnlyList<WasteStation>> GetSortedWasteStationsAsync(
        GeoPoint near, int rangeMeters, int? limit = null, CancellationToken ct = default)
    {
        var data = await GetAsync<FeatureCollection<WasteStationDto>>("/v2/sortedwastestations",
            new Query { { "latlng", near.ToLatLng() }, { "range", rangeMeters }, { "limit", limit } }, ct);

        return data.Select((s, location) => Lenient.Rounded(s.Id) is not { } id ? null : new WasteStation(
            id,
            s.Name ?? $"#{id}",
            s.District,
            location,
            s.Accessibility?.Description,
            [.. (s.Containers ?? []).Select(c => new WasteContainer(
                Lenient.Rounded(c.KsnkoId),
                ToWasteType(c.TrashType?.Id),
                c.TrashType?.Description,
                c.ContainerType,
                c.CleaningFrequency?.PickDays,
                Lenient.Date(c.CleaningFrequency?.NextPick),
                Lenient.Timestamp(c.LastPick),
                Lenient.Rounded(c.LastMeasurement?.PercentCalculated),
                Lenient.Timestamp(c.LastMeasurement?.MeasuredAtUtc)))]));
    }

    /// <summary>Upcoming bulky waste containers within <paramref name="rangeMeters"/> of a point, nearest first.</summary>
    public async Task<IReadOnlyList<BulkyWasteStation>> GetBulkyWasteStationsAsync(
        GeoPoint near, int rangeMeters, CancellationToken ct = default)
    {
        // This endpoint alone takes its range in whole kilometres, so ask for more and trim the result.
        var rangeKilometres = Math.Max(1, (int)Math.Ceiling(rangeMeters / 1000.0));
        var data = await GetAsync<FeatureCollection<BulkyWasteDto>>("/v1/bulky-waste/stations",
            new Query { { "latlng", near.ToLatLng() }, { "range", rangeKilometres } }, ct);

        return data.Select((s, location) =>
            Lenient.Date(s.Date) is not { } date || location.DistanceTo(near) > rangeMeters ? null : new BulkyWasteStation(
                s.CustomId,
                s.Street,
                s.CityDistrict,
                location,
                date,
                Lenient.Time(s.TimeFrom),
                Lenient.Time(s.TimeTo),
                s.ServiceName,
                Lenient.Rounded(s.NumberOfContainers)));
    }

    private static WasteType ToWasteType(double? id) =>
        Lenient.Rounded(id) is { } value && Enum.IsDefined((WasteType)value) ? (WasteType)value : WasteType.Unknown;
}

file sealed class WasteStationDto
{
    public double? Id { get; init; }
    public string? Name { get; init; }
    public string? District { get; init; }
    public DescribedDto? Accessibility { get; init; }
    public List<WasteContainerDto>? Containers { get; init; }
}

file sealed class DescribedDto
{
    public double? Id { get; init; }
    public string? Description { get; init; }
}

file sealed class WasteContainerDto
{
    public double? KsnkoId { get; init; }
    public string? ContainerType { get; init; }
    public DescribedDto? TrashType { get; init; }
    public CleaningFrequencyDto? CleaningFrequency { get; init; }
    public LastMeasurementDto? LastMeasurement { get; init; }
    public string? LastPick { get; init; }
}

file sealed class CleaningFrequencyDto
{
    public string? PickDays { get; init; }
    public string? NextPick { get; init; }
}

file sealed class LastMeasurementDto
{
    public string? MeasuredAtUtc { get; init; }
    public double? PercentCalculated { get; init; }
}

// Unlike the rest of the API, bulky waste uses camelCase.
file sealed class BulkyWasteDto
{
    [JsonPropertyName("customId")] public string? CustomId { get; init; }
    public string? Date { get; init; }
    [JsonPropertyName("timeFrom")] public string? TimeFrom { get; init; }
    [JsonPropertyName("timeTo")] public string? TimeTo { get; init; }
    public string? Street { get; init; }
    [JsonPropertyName("serviceName")] public string? ServiceName { get; init; }
    [JsonPropertyName("numberOfContainers")] public double? NumberOfContainers { get; init; }
    [JsonPropertyName("cityDistrict")] public string? CityDistrict { get; init; }
}
