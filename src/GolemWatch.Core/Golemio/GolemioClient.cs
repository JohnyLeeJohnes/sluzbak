using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.RateLimiting;

namespace GolemWatch.Core.Golemio;

/// <summary>
/// Authenticated, rate-limited HTTP access to api.golemio.cz.
/// The datasets are in the other parts of this class, one file per dataset.
/// </summary>
public sealed partial class GolemioClient : IDisposable
{
    public static readonly Uri BaseAddress = new("https://api.golemio.cz");

    /// <summary>The most rows the API returns for one request.</summary>
    internal const int PageSize = 10_000;

    internal static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        NumberHandling = JsonNumberHandling.AllowReadingFromString,
    };

    private readonly HttpClient _http;

    // Golemio allows 20 requests per 8 seconds per key; stay slightly under it.
    private readonly SlidingWindowRateLimiter _limiter = new(new SlidingWindowRateLimiterOptions
    {
        PermitLimit = 18,
        Window = TimeSpan.FromSeconds(8),
        SegmentsPerWindow = 8,
        QueueLimit = 200,
        QueueProcessingOrder = QueueProcessingOrder.OldestFirst,
    });

    public GolemioClient(string token, HttpMessageHandler? handler = null)
    {
        _http = new HttpClient(handler ?? new SocketsHttpHandler { AutomaticDecompression = DecompressionMethods.All })
        {
            BaseAddress = BaseAddress,
            Timeout = TimeSpan.FromSeconds(30),
        };

        try
        {
            _http.DefaultRequestHeaders.Add("X-Access-Token", token.Trim());
        }
        catch (FormatException e)
        {
            throw new GolemioException(GolemioError.Unauthorized, "The token contains characters that cannot be sent in a header.", e);
        }
    }

    internal async Task<T> GetAsync<T>(string path, Query? query = null, CancellationToken ct = default)
    {
        using var lease = await _limiter.AcquireAsync(1, ct);
        if (!lease.IsAcquired)
            throw new GolemioException(GolemioError.RateLimited, "Too many requests are already waiting.");

        var uri = query?.ToString() is { Length: > 0 } qs ? $"{path}?{qs}" : path;
        try
        {
            using var response = await _http.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, ct);
            if (!response.IsSuccessStatusCode)
            {
                // The body is usually {"error_message": "..."} and is the only hint about a rejected parameter.
                var body = await response.Content.ReadAsStringAsync(ct);
                throw new GolemioException(ToError(response.StatusCode),
                    $"GET {path} returned {(int)response.StatusCode}. {(body.Length > 300 ? body[..300] : body)}".TrimEnd());
            }

            return await response.Content.ReadFromJsonAsync<T>(Json, ct)
                ?? throw new GolemioException(GolemioError.Unexpected, $"GET {path} returned an empty body.");
        }
        catch (HttpRequestException e)
        {
            throw new GolemioException(GolemioError.Network, $"GET {path} failed: {e.Message}", e);
        }
        catch (TaskCanceledException e) when (!ct.IsCancellationRequested)
        {
            throw new GolemioException(GolemioError.Network, $"GET {path} timed out.", e);
        }
        catch (JsonException e)
        {
            throw UnexpectedShape(path, e);
        }
    }

    /// <summary>For endpoints whose specification describes a single object where a list is evidently meant.</summary>
    internal async Task<List<T>> GetListAsync<T>(string path, Query? query = null, CancellationToken ct = default)
    {
        var json = await GetAsync<JsonElement>(path, query, ct);
        try
        {
            if (json.ValueKind != JsonValueKind.Array)
                return json.Deserialize<T>(Json) is { } single ? [single] : [];
            return json.Deserialize<List<T>>(Json) ?? [];
        }
        catch (JsonException e)
        {
            throw UnexpectedShape(path, e);
        }
    }

    public void Dispose()
    {
        _http.Dispose();
        _limiter.Dispose();
    }

    /// <summary>"topLeft.lat,topLeft.lon,bottomRight.lat,bottomRight.lon" for the square reaching <paramref name="radiusMeters"/> from the center.</summary>
    private static string BoundingBox(GeoPoint center, double radiusMeters)
    {
        var (topLeft, bottomRight) = center.BoundingBox(radiusMeters);
        return $"{topLeft.ToLatLng()},{bottomRight.ToLatLng()}";
    }

    private static GolemioException UnexpectedShape(string path, JsonException e) =>
        new(GolemioError.Unexpected, $"GET {path} returned JSON in an unexpected shape: {e.Message}", e);

    private static GolemioError ToError(HttpStatusCode status) => status switch
    {
        HttpStatusCode.Unauthorized => GolemioError.Unauthorized,
        HttpStatusCode.Forbidden => GolemioError.Forbidden,
        HttpStatusCode.NotFound => GolemioError.NotFound,
        HttpStatusCode.TooManyRequests => GolemioError.RateLimited,
        _ => GolemioError.Unexpected,
    };
}
