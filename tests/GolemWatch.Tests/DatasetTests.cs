using GolemWatch.Core;
using GolemWatch.Core.Golemio;

namespace GolemWatch.Tests;

/// <summary>
/// Each dataset is fed the example from the Golemio OpenAPI specification and checked for the request it
/// sends and the model it builds. Nothing here talks to the real API; see <see cref="LiveApiTests"/> for that.
/// </summary>
public class DatasetTests
{
    private static readonly GeoPoint Prague = new(50.0755, 14.4378);

    [Theory]
    [InlineData("3", "3")]
    [InlineData("\"2A\"", "2A")]
    [InlineData("null", null)]
    public async Task Air_quality_stations(string indexJson, string? expectedIndex)
    {
        var http = StubHandler.Returning("""
            {"type":"FeatureCollection","features":[{"type":"Feature",
              "geometry":{"type":"Point","coordinates":[14.4633,50.07827]},
              "properties":{"id":"ACHOA","district":"praha-11","name":"Praha 4-Chodov","updated_at":"2019-05-18T07:38:37.000Z",
                "measurement":{"AQ_hourly_index":INDEX,"components":[{"averaged_time":{"averaged_hours":1,"value":10.7},"type":"NO2"}]}}}]}
            """.Replace("INDEX", indexJson));
        using var client = new GolemioClient("token", http);

        var station = Assert.Single(await client.GetAirQualityStationsAsync(Prague, rangeMeters: 3000));

        Assert.Equal("/v2/airqualitystations?latlng=50.0755,14.4378&range=3000", http.Request);
        Assert.Equal("ACHOA", station.Id);
        Assert.Equal("Praha 4-Chodov", station.Name);
        Assert.Equal("praha-11", station.District);
        Assert.Equal(new GeoPoint(50.07827, 14.4633), station.Location);
        Assert.Equal(expectedIndex, station.Index);
        Assert.Equal(new AirQualityComponent("NO2", 10.7, 1), Assert.Single(station.Components));
        Assert.Equal(new DateTimeOffset(2019, 5, 18, 7, 38, 37, TimeSpan.Zero), station.UpdatedAt);
    }

    [Fact]
    public async Task Air_quality_index_and_component_types()
    {
        using var client = new GolemioClient("token", new StubHandler(request => StubHandler.Reply(
            request.RequestUri!.AbsolutePath.EndsWith("indextypes")
                ? """[{"id":1,"index_code":"1A","limit_gte":0,"limit_lt":0.34,"color":"009900","color_text":"000000","description_cs":"velmi dobrá až dobrá","description_en":"very good to good"}]"""
                : """[{"id":1,"component_code":"SO2","unit":"µg/m³","description_cs":"oxid siřičitý","description_en":"sulfur dioxide"}]""")));

        var index = Assert.Single(await client.GetAirQualityIndexTypesAsync());
        var component = Assert.Single(await client.GetAirQualityComponentTypesAsync());

        Assert.Equal(new AirQualityIndexType(1, "1A", "009900", "000000", "velmi dobrá až dobrá", "very good to good"), index);
        Assert.True(index.Matches("1A"));
        Assert.True(index.Matches("1"));
        Assert.False(index.Matches("2"));
        Assert.False(index.Matches(null));
        Assert.Equal(new AirQualityComponentType("SO2", "µg/m³", "oxid siřičitý", "sulfur dioxide"), component);
    }

    private const string MicroclimatePoint = """
        {"point_id":131,"location_id":130,"point_named":"Pražská tržnice osvětlení","location":"Pražská Holešovická tržnice",
         "lat":50.098934,"lng":14.445023,"elevation_m":184.3,
         "measures":[{"measure":"air_temp200","measure_cz":"Teplota vzduchu, 200 cm","unit":"°C"}]}
        """;

    [Theory]
    [InlineData(MicroclimatePoint)] // what the specification documents
    [InlineData("[" + MicroclimatePoint + "]")] // what a list endpoint is expected to send
    public async Task Microclimate_points(string json)
    {
        var http = StubHandler.Returning(json);
        using var client = new GolemioClient("token", http);

        var point = Assert.Single(await client.GetMicroclimatePointsAsync());

        Assert.Equal("/v2/microclimate/points", http.Request);
        Assert.Equal(131, point.Id);
        Assert.Equal(130, point.LocationId);
        Assert.Equal("Pražská tržnice osvětlení", point.Name);
        Assert.Equal("Pražská Holešovická tržnice", point.LocationName);
        Assert.Equal(new GeoPoint(50.098934, 14.445023), point.Location);
        Assert.Equal(new MicroclimateMeasure("air_temp200", "Teplota vzduchu, 200 cm", "°C"), Assert.Single(point.Measures));
    }

    [Fact]
    public async Task Microclimate_measurements()
    {
        var http = StubHandler.Returning("""
            [{"point_id":131,"location_id":130,"measured_at":"2022-08-21T17:30:00.000Z","measure":"air_temp200","value":20,"unit":"°C"},
             {"point_id":131,"location_id":130,"measured_at":"2022-08-21T17:30:00.000Z","measure":"air_hum200","value":null,"unit":"%"}]
            """);
        using var client = new GolemioClient("token", http);

        var measurements = await client.GetMicroclimateMeasurementsAsync(131, new DateTimeOffset(2022, 8, 21, 17, 0, 0, TimeSpan.Zero));

        Assert.Equal("/v2/microclimate/measurements?pointId=131&from=2022-08-21T17:00:00Z", http.Request);
        Assert.Equal(
            new MicroclimateMeasurement(131, "air_temp200", 20, "°C", new DateTimeOffset(2022, 8, 21, 17, 30, 0, TimeSpan.Zero)),
            Assert.Single(measurements));
    }

    private const string ParkingJson = """
        {"type":"FeatureCollection","features":[{"type":"Feature",
          "geometry":{"type":"Polygon","coordinates":[[[14.4410,50.1090],[14.4420,50.1090],[14.4420,50.1100],[14.4410,50.1090]]]},
          "properties":{"id":"tsk2-P1-0101","primary_source":"tsk_v2","name":"Holešovice","capacity":74,
            "centroid":{"type":"Point","coordinates":[14.441252,50.109318]},
            "parking_type":"surface","parking_policy":"park_and_ride","has_occupancy_info":true,
            "address":{"address_formatted":"Plynární, 17000 Praha 7","street_address":"Plynární"}}},
         {"type":"Feature",
          "geometry":{"type":"Polygon","coordinates":[[[14.4310,50.0790],[14.4320,50.0790],[14.4320,50.0800],[14.4310,50.0790]]]},
          "properties":{"id":"osm-1","name":null,"capacity":null,"centroid":null,"parking_type":"underground","parking_policy":null,"has_occupancy_info":false,"address":null}}]}
        """;

    [Fact]
    public async Task Parking_without_street_zones()
    {
        var http = StubHandler.Returning(ParkingJson);
        using var client = new GolemioClient("token", http);

        var parking = await client.GetParkingAsync(Prague, radiusMeters: 500);

        var (topLeft, bottomRight) = Prague.BoundingBox(500);
        Assert.Equal(
            $"/v3/parking?boundingBox={topLeft.ToLatLng()},{bottomRight.ToLatLng()}"
            + "&parkingPolicy[]=commercial&parkingPolicy[]=customer_only&parkingPolicy[]=kiss_and_ride"
            + "&parkingPolicy[]=park_and_ride&parkingPolicy[]=park_sharing&parkingPolicy[]=none",
            http.Request);
        Assert.Equal(
            new Parking("tsk2-P1-0101", "Holešovice", new GeoPoint(50.109318, 14.441252), "surface", "park_and_ride", 74, true, "Plynární, 17000 Praha 7"),
            parking[0]);
        // Without a centroid the first corner of the outline has to do.
        Assert.Equal(new Parking("osm-1", null, new GeoPoint(50.0790, 14.4310), "underground", null, null, false, null), parking[1]);
        Assert.Equal(2, parking.Count);
    }

    [Fact]
    public async Task Parking_with_street_zones_sends_no_policy_filter()
    {
        var http = StubHandler.Returning(ParkingJson);
        using var client = new GolemioClient("token", http);

        await client.GetParkingAsync(Prague, radiusMeters: 500, includeZones: true);

        Assert.DoesNotContain("parkingPolicy", http.Request);
    }

    [Fact]
    public async Task Parking_occupancy()
    {
        var http = StubHandler.Returning("""
            [{"parking_id":"tsk2-P1-0101","primary_source":"tsk_v2","primary_source_id":"P1-0101","has_free_spots":true,
              "total_spot_number":74,"free_spot_number":12,"closed_spot_number":0,"occupied_spot_number":62,"last_updated":"2026-10-05T08:00:00.000Z"}]
            """);
        using var client = new GolemioClient("token", http);

        var occupancy = Assert.Single(await client.GetParkingOccupancyAsync(["tsk2-P1-0101", "osm-1"]));

        Assert.Equal("/v3/parking-measurements?parkingId[]=tsk2-P1-0101&parkingId[]=osm-1", http.Request);
        Assert.Equal(
            new ParkingOccupancy("tsk2-P1-0101", true, 74, 12, 62, 0, new DateTimeOffset(2026, 10, 5, 8, 0, 0, TimeSpan.Zero)),
            occupancy);
    }

    [Fact]
    public async Task Sorted_waste_stations()
    {
        // The specification's example verbatim, including the position wrapped in an extra array.
        var http = StubHandler.Returning("""
            {"features":[{"geometry":{"coordinates":[[14.416880835710145,50.089021646755796]],"type":"Point"},
              "properties":{"accessibility":{"description":"volně","id":1},
                "containers":[{"cleaning_frequency":{"id":21,"duration":"P2W","frequency":1,"pick_days":"Po, St, So","next_pick":"2021-03-31"},
                  "container_type":"3000 L Podzemní - SV","description":"string","trash_type":{"description":"Čiré sklo","id":7},
                  "last_measurement":{"measured_at_utc":"2021-08-27T14:00:32.000Z","percent_calculated":62,"prediction_utc":"2021-05-18T07:38:37.000Z"},
                  "last_pick":"2021-07-09T09:00:37.000Z","ksnko_id":15288,"container_id":15288,"sensor_code":15288,
                  "sensor_supplier":"Sensoneo","sensor_id":"Sensoneo_C00181","is_monitored":true},
                 {"cleaning_frequency":{"id":null,"duration":null,"frequency":null,"pick_days":"","next_pick":null},
                  "container_type":"1100 L","trash_type":{"description":"Nový druh","id":42},"last_measurement":null,"last_pick":null,"ksnko_id":"15289"}],
                "district":"praha-22","id":1,"name":"Přátelství 356/61","station_number":"0022/ 001",
                "updated_at":"2019-05-18T07:38:37.000Z","is_monitored":true,"ksnko_id":3497},"type":"Feature"}],
             "type":"FeatureCollection"}
            """);
        using var client = new GolemioClient("token", http);

        var station = Assert.Single(await client.GetSortedWasteStationsAsync(Prague, rangeMeters: 300, limit: 20));

        Assert.Equal("/v2/sortedwastestations?latlng=50.0755,14.4378&range=300&limit=20", http.Request);
        Assert.Equal(1, station.Id);
        Assert.Equal("Přátelství 356/61", station.Name);
        Assert.Equal("praha-22", station.District);
        Assert.Equal(new GeoPoint(50.089021646755796, 14.416880835710145), station.Location);
        Assert.Equal("volně", station.Accessibility);
        Assert.Equal(
            [
                new WasteContainer(15288, WasteType.ClearGlass, "Čiré sklo", "3000 L Podzemní - SV", "Po, St, So",
                    new DateOnly(2021, 3, 31), new DateTimeOffset(2021, 7, 9, 9, 0, 37, TimeSpan.Zero),
                    62, new DateTimeOffset(2021, 8, 27, 14, 0, 32, TimeSpan.Zero)),
                new WasteContainer(15289, WasteType.Unknown, "Nový druh", "1100 L", "", null, null, null, null),
            ],
            station.Containers);
    }

    [Fact]
    public async Task Bulky_waste_asks_in_kilometres_and_trims_to_the_requested_range()
    {
        var near = new GeoPoint(50.0805, 14.4378); // about 556 m north of Prague
        var http = StubHandler.Returning("""
            {"features":[
              {"geometry":{"coordinates":[14.4378,50.0805],"type":"Point"},
               "properties":{"customId":"2019-05-18 14:00 ID:85298","date":"2019-05-18","timeFrom":"14:00:00","timeTo":"18:00:00",
                 "street":"Přátelství 356/61","serviceName":"VOK","payer":"municipality","numberOfContainers":1,"cityDistrict":"praha-22"},"type":"Feature"},
              {"geometry":{"coordinates":[14.4378,50.0915],"type":"Point"},
               "properties":{"customId":"1.8 km north","date":"2019-05-19","timeFrom":"09:00:00","timeTo":"13:00:00","street":"Daleká 1"},"type":"Feature"}],
             "type":"FeatureCollection"}
            """);
        using var client = new GolemioClient("token", http);

        var station = Assert.Single(await client.GetBulkyWasteStationsAsync(Prague, rangeMeters: 1500));

        Assert.Equal("/v1/bulky-waste/stations?latlng=50.0755,14.4378&range=2", http.Request);
        Assert.Equal(
            new BulkyWasteStation("2019-05-18 14:00 ID:85298", "Přátelství 356/61", "praha-22", near,
                new DateOnly(2019, 5, 18), new TimeOnly(14, 0), new TimeOnly(18, 0), "VOK", 1),
            station);
    }

    [Fact]
    public async Task Stops_are_read_page_by_page_and_only_boardable_ones_are_kept()
    {
        static string Stop(string id, int locationType) =>
            $$$"""{"type":"Feature","geometry":{"type":"Point","coordinates":[14.45,50.08]},"properties":{"location_type":{{{locationType}}},"parent_station":null,"platform_code":"A","stop_id":"{{{id}}}","stop_name":"Flora","wheelchair_boarding":2,"zone_id":"P","level_id":null}}""";
        static string Page(IEnumerable<string> stops) => $$"""{"type":"FeatureCollection","features":[{{string.Join(',', stops)}}]}""";

        var http = new StubHandler(request => StubHandler.Reply(request.RequestUri!.Query.EndsWith("offset=0")
            ? Page(Enumerable.Range(0, GolemioClient.PageSize).Select(i => Stop($"U{i}", locationType: 0)))
            : Page([Stop("U118Z101P", locationType: 0), Stop("U118S1", locationType: 1)])));
        using var client = new GolemioClient("token", http);

        var stops = await client.GetStopsAsync();

        Assert.Equal(
            ["/v2/gtfs/stops?limit=10000&offset=0", "/v2/gtfs/stops?limit=10000&offset=10000"],
            http.Requests.Select(StubHandler.PathAndQuery));
        Assert.Equal(GolemioClient.PageSize + 1, stops.Count);
        Assert.Equal(new TransitStop("U118Z101P", "Flora", "A", new GeoPoint(50.08, 14.45), "P"), stops[^1]);
    }

    [Fact]
    public async Task Departures()
    {
        var http = StubHandler.Returning("""
            {"stops":[{"level_id":null,"location_type":0,"parent_station":"U118S1","platform_code":"A","stop_lat":50.07804,"stop_lon":14.46173,
               "asw_id":{"node":118,"stop":101},"stop_id":"U118Z101P","stop_name":"Flora","wheelchair_boarding":1,"zone_id":"P"}],
             "departures":[
              {"arrival_timestamp":{"predicted":"2026-10-05T09:38:20+02:00","scheduled":"2026-10-05T09:38:00+02:00","minutes":"<1"},
               "delay":{"is_available":true,"minutes":3,"seconds":176},
               "departure_timestamp":{"predicted":"2026-10-05T09:40:56+02:00","scheduled":"2026-10-05T09:38:00+02:00","minutes":"3"},
               "last_stop":{"name":"Prosecká","id":"U754Z1P"},
               "route":{"short_name":"A","type":1,"is_night":false,"is_regional":false,"is_substitute_transport":false},
               "stop":{"id":"U118Z101P","platform_code":"A"},
               "trip":{"direction":null,"headsign":"Depo Hostivař","id":"991_224_200302","is_at_stop":false,"is_canceled":false,
                 "is_wheelchair_accessible":true,"is_air_conditioned":null,"short_name":null}},
              {"delay":{"is_available":false,"minutes":null,"seconds":null},
               "departure_timestamp":{"predicted":"2026-10-05T09:45:00+02:00","scheduled":"2026-10-05T09:45:00+02:00","minutes":"7"},
               "route":{"short_name":"136","type":3},
               "stop":{"id":"U118Z2P","platform_code":null},
               "trip":{"headsign":"Vozovna Kobylisy","id":"136_1","is_at_stop":false,"is_canceled":true,"is_wheelchair_accessible":false,"is_air_conditioned":true}}],
             "infotexts":[{"valid_from":"2026-10-05T08:00:00+02:00","valid_to":null,"text":"Nehoda na trase, odklon linek mimo tuto stanici.",
               "text_en":"Trips are cancelled due to accident on route.","display_type":"inline","related_stops":["U118S1"]}]}
            """);
        using var client = new GolemioClient("token", http);

        var board = await client.GetDeparturesAsync(["U118Z101P", "U118Z2P"], minutesAfter: 30, limit: 10);

        Assert.Equal("/v2/pid/departureboards?ids[]=U118Z101P&ids[]=U118Z2P&minutesAfter=30&limit=10", http.Request);
        Assert.Equal(new TransitStop("U118Z101P", "Flora", "A", new GeoPoint(50.07804, 14.46173), "P"), Assert.Single(board.Stops));
        var cest = TimeSpan.FromHours(2);
        Assert.Equal(
            [
                new Departure("U118Z101P", "A", "A", TransitMode.Metro, "Depo Hostivař",
                    new DateTimeOffset(2026, 10, 5, 9, 38, 0, cest), new DateTimeOffset(2026, 10, 5, 9, 40, 56, cest),
                    176, IsCanceled: false, IsAtStop: false, IsWheelchairAccessible: true, IsAirConditioned: null),
                new Departure("U118Z2P", null, "136", TransitMode.Bus, "Vozovna Kobylisy",
                    new DateTimeOffset(2026, 10, 5, 9, 45, 0, cest), new DateTimeOffset(2026, 10, 5, 9, 45, 0, cest),
                    null, IsCanceled: true, IsAtStop: false, IsWheelchairAccessible: false, IsAirConditioned: true),
            ],
            board.Departures);
        Assert.Equal(
            new Infotext("Nehoda na trase, odklon linek mimo tuto stanici.", "Trips are cancelled due to accident on route.",
                new DateTimeOffset(2026, 10, 5, 8, 0, 0, cest), null),
            Assert.Single(board.Infotexts));
    }

    [Fact]
    public async Task Vehicle_positions()
    {
        var http = StubHandler.Returning("""
            {"features":[{"geometry":{"coordinates":[14.4378,50.0755],"type":"Point"},
              "properties":{"gtfs_trip_id":"705_735_231002","route_type":"bus","gtfs_route_short_name":"705","bearing":221,"delay":20,
                "vehicle_id":"service-3-8585","state_position":"at_stop"},"type":"Feature"}],"type":"FeatureCollection"}
            """);
        using var client = new GolemioClient("token", http);

        var vehicle = Assert.Single(await client.GetVehiclePositionsAsync(Prague, radiusMeters: 1000));

        var (topLeft, bottomRight) = Prague.BoundingBox(1000);
        Assert.Equal($"/v2/public/vehiclepositions?boundingBox={topLeft.ToLatLng()},{bottomRight.ToLatLng()}", http.Request);
        Assert.Equal(new VehiclePosition("service-3-8585", "705_735_231002", "705", TransitMode.Bus, Prague, 221, 20, "at_stop"), vehicle);
    }

    [Fact]
    public async Task Nothing_is_requested_when_there_is_nothing_to_ask_about()
    {
        var http = StubHandler.Returning("[]");
        using var client = new GolemioClient("token", http);

        Assert.Empty(await client.GetParkingOccupancyAsync([]));
        Assert.Same(DepartureBoard.Empty, await client.GetDeparturesAsync([]));
        Assert.Empty(http.Requests);
    }

    [Fact]
    public async Task Features_without_a_usable_position_or_id_are_skipped()
    {
        var http = StubHandler.Returning("""
            {"features":[
              {"geometry":null,"properties":{"vehicle_id":"no-geometry"}},
              {"geometry":{"coordinates":[],"type":"Point"},"properties":{"vehicle_id":"empty-position"}},
              {"geometry":{"coordinates":[14.4,950.0],"type":"Point"},"properties":{"vehicle_id":"off-the-planet"}},
              {"geometry":{"coordinates":[14.4,50.0],"type":"Point"},"properties":{"gtfs_trip_id":"no-vehicle-id"}},
              {"geometry":{"coordinates":[14.4,50.0],"type":"Point"},"properties":null},
              {"geometry":{"coordinates":[14.4,50.0],"type":"Point"},"properties":{"vehicle_id":"ok","delay":null,"bearing":null}}]}
            """);
        using var client = new GolemioClient("token", http);

        var vehicle = Assert.Single(await client.GetVehiclePositionsAsync(Prague, radiusMeters: 1000));

        Assert.Equal(new VehiclePosition("ok", null, null, TransitMode.Unknown, new GeoPoint(50.0, 14.4), null, null, null), vehicle);
    }
}
