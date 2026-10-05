using System.Globalization;
using GolemWatch.Core;

namespace GolemWatch.Tests;

public class GeoPointTests
{
    private static readonly GeoPoint Prague = new(50.0755, 14.4378);

    [Fact]
    public void One_degree_of_latitude_is_about_111_km()
    {
        Assert.Equal(111_195, new GeoPoint(50, 14).DistanceTo(new GeoPoint(51, 14)), tolerance: 1);
        Assert.Equal(0, Prague.DistanceTo(Prague));
    }

    [Fact]
    public void Bounding_box_sides_are_the_radius_away()
    {
        var (topLeft, bottomRight) = Prague.BoundingBox(500);

        Assert.True(topLeft.Latitude > Prague.Latitude && topLeft.Longitude < Prague.Longitude);
        Assert.True(bottomRight.Latitude < Prague.Latitude && bottomRight.Longitude > Prague.Longitude);
        Assert.Equal(500, Prague.DistanceTo(new GeoPoint(topLeft.Latitude, Prague.Longitude)), tolerance: 0.5);
        Assert.Equal(500, Prague.DistanceTo(new GeoPoint(Prague.Latitude, bottomRight.Longitude)), tolerance: 0.5);
    }

    [Fact]
    public void Coordinates_are_formatted_with_a_decimal_point_under_a_Czech_culture()
    {
        var previous = CultureInfo.CurrentCulture;
        CultureInfo.CurrentCulture = new CultureInfo("cs-CZ");
        try
        {
            Assert.Equal("50.0755,14.4378", Prague.ToLatLng());
        }
        finally
        {
            CultureInfo.CurrentCulture = previous;
        }
    }

    [Theory]
    [InlineData("50.0755", 50.0755)]
    [InlineData(" 50,0755 ", 50.0755)]
    [InlineData("-14", -14)]
    public void Coordinates_are_parsed_with_a_point_or_a_comma(string text, double expected)
    {
        Assert.True(GeoPoint.TryParseCoordinate(text, out var value));
        Assert.Equal(expected, value);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("Praha")]
    public void Text_that_is_not_a_number_is_rejected(string? text) =>
        Assert.False(GeoPoint.TryParseCoordinate(text, out _));

    [Theory]
    [InlineData(50, 14, true)]
    [InlineData(91, 14, false)]
    [InlineData(50, 181, false)]
    public void Validity_follows_the_WGS84_ranges(double latitude, double longitude, bool valid) =>
        Assert.Equal(valid, new GeoPoint(latitude, longitude).IsValid);
}
