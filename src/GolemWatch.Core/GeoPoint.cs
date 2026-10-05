using System.Globalization;

namespace GolemWatch.Core;

/// <summary>WGS84 coordinate.</summary>
public readonly record struct GeoPoint(double Latitude, double Longitude)
{
    private const double EarthRadiusMeters = 6_371_000;

    public bool IsValid => Latitude is >= -90 and <= 90 && Longitude is >= -180 and <= 180;

    /// <summary>Great-circle distance in meters.</summary>
    public double DistanceTo(GeoPoint other)
    {
        var dLat = ToRadians(other.Latitude - Latitude);
        var dLon = ToRadians(other.Longitude - Longitude);
        var a = Math.Pow(Math.Sin(dLat / 2), 2)
              + Math.Cos(ToRadians(Latitude)) * Math.Cos(ToRadians(other.Latitude)) * Math.Pow(Math.Sin(dLon / 2), 2);
        return 2 * EarthRadiusMeters * Math.Asin(Math.Sqrt(a));
    }

    /// <summary>Corners of a square around the point whose sides are <paramref name="radiusMeters"/> away from it.</summary>
    public (GeoPoint TopLeft, GeoPoint BottomRight) BoundingBox(double radiusMeters)
    {
        var dLat = radiusMeters / EarthRadiusMeters * 180 / Math.PI;
        var dLon = dLat / Math.Cos(ToRadians(Latitude));
        return (new(Latitude + dLat, Longitude - dLon), new(Latitude - dLat, Longitude + dLon));
    }

    /// <summary>"lat,lng", the order Golemio expects.</summary>
    public string ToLatLng() => string.Create(CultureInfo.InvariantCulture, $"{Latitude:0.######},{Longitude:0.######}");

    /// <summary>Parses a coordinate typed with either a decimal point or a decimal comma.</summary>
    public static bool TryParseCoordinate(string? text, out double value) =>
        double.TryParse(text?.Trim().Replace(',', '.'), NumberStyles.Float, CultureInfo.InvariantCulture, out value);

    private static double ToRadians(double degrees) => degrees * Math.PI / 180;
}
