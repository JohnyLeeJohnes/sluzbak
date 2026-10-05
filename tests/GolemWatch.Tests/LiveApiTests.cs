using GolemWatch.Core;
using GolemWatch.Core.Golemio;

namespace GolemWatch.Tests;

/// <summary>Runs only when the GOLEMIO_TOKEN environment variable holds an API key.</summary>
public sealed class LiveFactAttribute : FactAttribute
{
    public const string TokenVariable = "GOLEMIO_TOKEN";

    public LiveFactAttribute()
    {
        if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(TokenVariable)))
            Skip = $"Set {TokenVariable} to run against the live Golemio API.";
    }
}

/// <summary>
/// Calls the real API once per dataset. The other tests only know the specification, so this is what shows
/// where the live responses differ from it.
/// </summary>
public class LiveApiTests
{
    private static readonly GeoPoint Prague = new(50.0755, 14.4378);

    private static GolemioClient Client() => new(Environment.GetEnvironmentVariable(LiveFactAttribute.TokenVariable)!);

    [LiveFact]
    public async Task Air_quality()
    {
        using var client = Client();

        var stations = await client.GetAirQualityStationsAsync(Prague, limit: 5);
        var indexTypes = await client.GetAirQualityIndexTypesAsync();

        Assert.NotEmpty(stations);
        Assert.NotEmpty(await client.GetAirQualityComponentTypesAsync());
        Assert.All(stations.Where(s => s.Index is not null), s => Assert.Contains(indexTypes, t => t.Matches(s.Index)));
    }

    [LiveFact]
    public async Task Microclimate()
    {
        using var client = Client();

        var points = await client.GetMicroclimatePointsAsync();

        Assert.NotEmpty(points);
        var nearest = points.MinBy(p => p.Location.DistanceTo(Prague))!;
        await client.GetMicroclimateMeasurementsAsync(nearest.Id, DateTimeOffset.UtcNow.AddHours(-6));
    }

    [LiveFact]
    public async Task Parking()
    {
        using var client = Client();

        var parking = await client.GetParkingAsync(Prague, radiusMeters: 2000);

        Assert.NotEmpty(parking);
        Assert.DoesNotContain(parking, p => p.Policy == "zone");
        await client.GetParkingOccupancyAsync(parking.Where(p => p.HasOccupancyInfo).Select(p => p.Id).Take(20));
    }

    [LiveFact]
    public async Task Waste()
    {
        using var client = Client();

        var stations = await client.GetSortedWasteStationsAsync(Prague, rangeMeters: 500);

        Assert.NotEmpty(stations);
        Assert.Contains(stations.SelectMany(s => s.Containers), c => c.Type != WasteType.Unknown);
        await client.GetBulkyWasteStationsAsync(Prague, rangeMeters: 3000);
    }

    [LiveFact]
    public async Task Public_transport()
    {
        using var client = Client();

        var stops = await client.GetStopsAsync();
        Assert.NotEmpty(stops);

        var nearest = stops.OrderBy(s => s.Location.DistanceTo(Prague)).Take(3).Select(s => s.Id);
        var board = await client.GetDeparturesAsync(nearest);
        Assert.NotEmpty(board.Stops);

        await client.GetVehiclePositionsAsync(Prague, radiusMeters: 2000);
    }
}
