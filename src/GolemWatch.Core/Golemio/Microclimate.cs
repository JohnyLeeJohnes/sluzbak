namespace GolemWatch.Core.Golemio;

/// <summary>A sensor of the microclimate network and the quantities it measures.</summary>
public sealed record MicroclimatePoint(
    int Id,
    int? LocationId,
    string Name,
    string? LocationName,
    GeoPoint Location,
    IReadOnlyList<MicroclimateMeasure> Measures);

/// <param name="Code">Identifier used by <see cref="MicroclimateMeasurement.Measure"/>, e.g. air_temp200.</param>
public sealed record MicroclimateMeasure(string Code, string? NameCs, string? Unit);

public sealed record MicroclimateMeasurement(int PointId, string Measure, double Value, string? Unit, DateTimeOffset MeasuredAt);

public sealed partial class GolemioClient
{
    /// <summary>Every sensor; the endpoint has no location filter, so pick the nearest with <see cref="GeoPoint.DistanceTo"/>.</summary>
    public async Task<IReadOnlyList<MicroclimatePoint>> GetMicroclimatePointsAsync(CancellationToken ct = default)
    {
        var data = await GetListAsync<MicroclimatePointDto>("/v2/microclimate/points", null, ct);

        var points = new List<MicroclimatePoint>();
        foreach (var p in data)
        {
            if (Lenient.Rounded(p.PointId) is not { } id || Lenient.Point(p.Lat, p.Lng) is not { } location)
                continue;

            points.Add(new MicroclimatePoint(
                id,
                Lenient.Rounded(p.LocationId),
                p.PointNamed ?? p.PointName ?? p.Location ?? $"#{id}",
                p.Location,
                location,
                [.. (p.Measures ?? [])
                    .Where(m => m.Measure is not null)
                    .Select(m => new MicroclimateMeasure(m.Measure!, m.MeasureCz, m.Unit))]));
        }
        return points;
    }

    /// <summary>Readings of one sensor taken since <paramref name="from"/>, for all of its measures.</summary>
    public async Task<IReadOnlyList<MicroclimateMeasurement>> GetMicroclimateMeasurementsAsync(
        int pointId, DateTimeOffset from, CancellationToken ct = default)
    {
        var data = await GetAsync<List<MicroclimateMeasurementDto>>("/v2/microclimate/measurements",
            new Query { { "pointId", pointId }, { "from", from } }, ct);

        var measurements = new List<MicroclimateMeasurement>();
        foreach (var m in data)
        {
            if (m is { Measure: { } measure, Value: { } value } && Lenient.Timestamp(m.MeasuredAt) is { } measuredAt)
                measurements.Add(new MicroclimateMeasurement(Lenient.Rounded(m.PointId) ?? pointId, measure, value, m.Unit, measuredAt));
        }
        return measurements;
    }
}

file sealed class MicroclimatePointDto
{
    public double? PointId { get; init; }
    public double? LocationId { get; init; }
    // The points endpoint documents "point_named" while the locations endpoint uses "point_name".
    public string? PointNamed { get; init; }
    public string? PointName { get; init; }
    public string? Location { get; init; }
    public double? Lat { get; init; }
    public double? Lng { get; init; }
    public List<MicroclimateMeasureDto>? Measures { get; init; }
}

file sealed class MicroclimateMeasureDto
{
    public string? Measure { get; init; }
    public string? MeasureCz { get; init; }
    public string? Unit { get; init; }
}

file sealed class MicroclimateMeasurementDto
{
    public double? PointId { get; init; }
    public string? MeasuredAt { get; init; }
    public string? Measure { get; init; }
    public double? Value { get; init; }
    public string? Unit { get; init; }
}
