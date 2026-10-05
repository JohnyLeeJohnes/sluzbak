namespace GolemWatch.Core.Golemio;

/// <param name="Type">on_street, underground, multi_storey, surface, rooftop or other.</param>
/// <param name="Policy">park_and_ride, kiss_and_ride, commercial, zone, park_sharing, customer_only or null.</param>
public sealed record Parking(
    string Id,
    string? Name,
    GeoPoint Location,
    string? Type,
    string? Policy,
    int? Capacity,
    bool HasOccupancyInfo,
    string? Address);

public sealed record ParkingOccupancy(
    string ParkingId,
    bool HasFreeSpots,
    int? Total,
    int? Free,
    int? Occupied,
    int? Closed,
    DateTimeOffset? UpdatedAt);

public sealed partial class GolemioClient
{
    // Every documented policy except "zone"; "none" stands for parking without a policy.
    private static readonly string[] PoliciesWithoutZones =
        ["commercial", "customer_only", "kiss_and_ride", "park_and_ride", "park_sharing", "none"];

    /// <summary>
    /// Parking in the square reaching <paramref name="radiusMeters"/> from a point. Street parking zones are
    /// left out unless asked for, because a city block has dozens of them.
    /// </summary>
    public async Task<IReadOnlyList<Parking>> GetParkingAsync(
        GeoPoint near, double radiusMeters, bool includeZones = false, CancellationToken ct = default)
    {
        var query = new Query { { "boundingBox", BoundingBox(near, radiusMeters) } };
        if (!includeZones)
            query.Add("parkingPolicy[]", PoliciesWithoutZones);

        var data = await GetAsync<FeatureCollection<ParkingDto>>("/v3/parking", query, ct);

        // The geometry is usually the outline of the lot, so prefer the centroid for a single position.
        return data.Select((p, outline) => p.Id is null ? null : new Parking(
            p.Id,
            p.Name,
            Lenient.Point(p.Centroid?.Coordinates ?? default) ?? outline,
            p.ParkingType,
            p.ParkingPolicy,
            Lenient.Rounded(p.Capacity),
            p.HasOccupancyInfo ?? false,
            p.Address?.AddressFormatted));
    }

    /// <summary>Current occupancy of the given parking; only those that report it come back.</summary>
    public async Task<IReadOnlyList<ParkingOccupancy>> GetParkingOccupancyAsync(
        IEnumerable<string> parkingIds, CancellationToken ct = default)
    {
        var query = new Query { { "parkingId[]", parkingIds } };
        if (!query.Any())
            return [];

        var data = await GetAsync<List<ParkingMeasurementDto>>("/v3/parking-measurements", query, ct);
        return [.. data
            .Where(m => m.ParkingId is not null)
            .Select(m => new ParkingOccupancy(
                m.ParkingId!,
                m.HasFreeSpots ?? false,
                Lenient.Rounded(m.TotalSpotNumber),
                Lenient.Rounded(m.FreeSpotNumber),
                Lenient.Rounded(m.OccupiedSpotNumber),
                Lenient.Rounded(m.ClosedSpotNumber),
                Lenient.Timestamp(m.LastUpdated)))];
    }
}

file sealed class ParkingDto
{
    public string? Id { get; init; }
    public string? Name { get; init; }
    public Geometry? Centroid { get; init; }
    public string? ParkingType { get; init; }
    public string? ParkingPolicy { get; init; }
    public double? Capacity { get; init; }
    public bool? HasOccupancyInfo { get; init; }
    public ParkingAddressDto? Address { get; init; }
}

file sealed class ParkingAddressDto
{
    public string? AddressFormatted { get; init; }
}

file sealed class ParkingMeasurementDto
{
    public string? ParkingId { get; init; }
    public bool? HasFreeSpots { get; init; }
    public double? TotalSpotNumber { get; init; }
    public double? FreeSpotNumber { get; init; }
    public double? OccupiedSpotNumber { get; init; }
    public double? ClosedSpotNumber { get; init; }
    public string? LastUpdated { get; init; }
}
