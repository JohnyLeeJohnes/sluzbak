namespace GolemWatch.Core.Golemio;

public enum TransitMode
{
    Unknown,
    Tram,
    Metro,
    Train,
    Bus,
    Ferry,
    Funicular,
    Trolleybus,
}

/// <summary>A place where vehicles stop; a named stop usually has one of these per platform.</summary>
public sealed record TransitStop(string Id, string Name, string? Platform, GeoPoint Location, string? Zone);

/// <param name="Scheduled">Departure according to the timetable.</param>
/// <param name="Predicted">Departure including the current delay.</param>
/// <param name="DelaySeconds">Null when the vehicle is not being tracked.</param>
public sealed record Departure(
    string StopId,
    string? Platform,
    string? Route,
    TransitMode Mode,
    string? Headsign,
    DateTimeOffset? Scheduled,
    DateTimeOffset? Predicted,
    int? DelaySeconds,
    bool IsCanceled,
    bool IsAtStop,
    bool? IsWheelchairAccessible,
    bool? IsAirConditioned);

/// <summary>A notice shown on departure boards, such as a diversion.</summary>
public sealed record Infotext(string Text, string? TextEn, DateTimeOffset? ValidFrom, DateTimeOffset? ValidTo);

public sealed record DepartureBoard(
    IReadOnlyList<TransitStop> Stops,
    IReadOnlyList<Departure> Departures,
    IReadOnlyList<Infotext> Infotexts)
{
    public static readonly DepartureBoard Empty = new([], [], []);
}

/// <param name="State">at_stop, before_track, before_track_delayed, canceled, off_track or on_track.</param>
public sealed record VehiclePosition(
    string VehicleId,
    string? TripId,
    string? Route,
    TransitMode Mode,
    GeoPoint Location,
    double? Bearing,
    int? DelaySeconds,
    string? State);

public sealed partial class GolemioClient
{
    /// <summary>
    /// Every PID stop and platform. The endpoint has no location filter, so this reads the whole list in pages
    /// of 10 000; fetch it once and search it with <see cref="GeoPoint.DistanceTo"/>.
    /// </summary>
    public async Task<IReadOnlyList<TransitStop>> GetStopsAsync(CancellationToken ct = default)
    {
        var stops = new List<TransitStop>();
        for (var offset = 0; ; offset += PageSize)
        {
            var page = await GetAsync<FeatureCollection<StopDto>>("/v2/gtfs/stops",
                new Query { { "limit", PageSize }, { "offset", offset } }, ct);

            // location_type 0 is a boardable stop or platform; stations, entrances and other nodes have no departures.
            stops.AddRange(page.Select((s, location) => s.StopId is null || s.LocationType is not (null or 0)
                ? null
                : new TransitStop(s.StopId, s.StopName ?? s.StopId, s.PlatformCode, location, s.ZoneId)));

            if ((page.Features?.Count ?? 0) < PageSize)
                return stops;
        }
    }

    /// <summary>Departures from up to 100 stops within the next <paramref name="minutesAfter"/> minutes, soonest first.</summary>
    public async Task<DepartureBoard> GetDeparturesAsync(
        IEnumerable<string> stopIds, int minutesAfter = 60, int limit = 20, CancellationToken ct = default)
    {
        var query = new Query { { "ids[]", stopIds } };
        if (!query.Any())
            return DepartureBoard.Empty;
        query.Add("minutesAfter", minutesAfter);
        query.Add("limit", limit);

        var data = await GetAsync<DepartureBoardDto>("/v2/pid/departureboards", query, ct);

        var stops = new List<TransitStop>();
        foreach (var s in data.Stops ?? [])
        {
            if (s.StopId is not null && Lenient.Point(s.StopLat, s.StopLon) is { } location)
                stops.Add(new TransitStop(s.StopId, s.StopName ?? s.StopId, s.PlatformCode, location, s.ZoneId));
        }

        return new DepartureBoard(
            stops,
            [.. (data.Departures ?? [])
                .Where(d => d.Stop?.Id is not null)
                .Select(d => new Departure(
                    d.Stop!.Id!,
                    d.Stop.PlatformCode,
                    d.Route?.ShortName,
                    FromGtfsRouteType(d.Route?.Type),
                    d.Trip?.Headsign,
                    Lenient.Timestamp(d.DepartureTimestamp?.Scheduled),
                    Lenient.Timestamp(d.DepartureTimestamp?.Predicted),
                    d.Delay?.IsAvailable == true ? Lenient.Rounded(d.Delay.Seconds) : null,
                    d.Trip?.IsCanceled ?? false,
                    d.Trip?.IsAtStop ?? false,
                    d.Trip?.IsWheelchairAccessible,
                    d.Trip?.IsAirConditioned))],
            [.. (data.Infotexts ?? [])
                .Where(i => !string.IsNullOrWhiteSpace(i.Text))
                .Select(i => new Infotext(i.Text!, i.TextEn, Lenient.Timestamp(i.ValidFrom), Lenient.Timestamp(i.ValidTo)))]);
    }

    /// <summary>Vehicles currently in the square reaching <paramref name="radiusMeters"/> from a point.</summary>
    public async Task<IReadOnlyList<VehiclePosition>> GetVehiclePositionsAsync(
        GeoPoint near, double radiusMeters, CancellationToken ct = default)
    {
        var data = await GetAsync<FeatureCollection<VehicleDto>>("/v2/public/vehiclepositions",
            new Query { { "boundingBox", BoundingBox(near, radiusMeters) } }, ct);

        return data.Select((v, location) => v.VehicleId is null ? null : new VehiclePosition(
            v.VehicleId,
            v.GtfsTripId,
            v.GtfsRouteShortName,
            FromRouteTypeName(v.RouteType),
            location,
            v.Bearing,
            Lenient.Rounded(v.Delay),
            v.StatePosition));
    }

    /// <summary>GTFS route_type numbers as PID uses them.</summary>
    private static TransitMode FromGtfsRouteType(double? type) => type switch
    {
        0 => TransitMode.Tram,
        1 => TransitMode.Metro,
        2 => TransitMode.Train,
        3 => TransitMode.Bus,
        4 => TransitMode.Ferry,
        7 => TransitMode.Funicular,
        11 => TransitMode.Trolleybus,
        _ => TransitMode.Unknown,
    };

    private static TransitMode FromRouteTypeName(string? name) => name switch
    {
        "tram" => TransitMode.Tram,
        "metro" => TransitMode.Metro,
        "train" => TransitMode.Train,
        "bus" => TransitMode.Bus,
        "ferry" => TransitMode.Ferry,
        "funicular" => TransitMode.Funicular,
        "trolleybus" => TransitMode.Trolleybus,
        _ => TransitMode.Unknown,
    };
}

file sealed class StopDto
{
    public string? StopId { get; init; }
    public string? StopName { get; init; }
    public string? PlatformCode { get; init; }
    public string? ZoneId { get; init; }
    public double? LocationType { get; init; }
    public double? StopLat { get; init; }
    public double? StopLon { get; init; }
}

file sealed class DepartureBoardDto
{
    public List<StopDto>? Stops { get; init; }
    public List<DepartureDto>? Departures { get; init; }
    public List<InfotextDto>? Infotexts { get; init; }
}

file sealed class DepartureDto
{
    public DepartureTimestampDto? DepartureTimestamp { get; init; }
    public DelayDto? Delay { get; init; }
    public RouteDto? Route { get; init; }
    public DepartureStopDto? Stop { get; init; }
    public TripDto? Trip { get; init; }
}

file sealed class DepartureTimestampDto
{
    public string? Predicted { get; init; }
    public string? Scheduled { get; init; }
}

file sealed class DelayDto
{
    public bool? IsAvailable { get; init; }
    public double? Seconds { get; init; }
}

file sealed class RouteDto
{
    public string? ShortName { get; init; }
    public double? Type { get; init; }
}

file sealed class DepartureStopDto
{
    public string? Id { get; init; }
    public string? PlatformCode { get; init; }
}

file sealed class TripDto
{
    public string? Headsign { get; init; }
    public bool? IsAtStop { get; init; }
    public bool? IsCanceled { get; init; }
    public bool? IsWheelchairAccessible { get; init; }
    public bool? IsAirConditioned { get; init; }
}

file sealed class InfotextDto
{
    public string? Text { get; init; }
    public string? TextEn { get; init; }
    public string? ValidFrom { get; init; }
    public string? ValidTo { get; init; }
}

file sealed class VehicleDto
{
    public string? VehicleId { get; init; }
    public string? GtfsTripId { get; init; }
    public string? GtfsRouteShortName { get; init; }
    public string? RouteType { get; init; }
    public double? Bearing { get; init; }
    public double? Delay { get; init; }
    public string? StatePosition { get; init; }
}
