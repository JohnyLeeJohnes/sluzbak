using System.Globalization;
using System.Net;
using GolemWatch.Core.Golemio;

namespace GolemWatch.Tests;

public class GolemioClientTests
{
    [Fact]
    public async Task The_token_is_sent_in_the_access_token_header()
    {
        var http = StubHandler.Returning("[]");
        using var client = new GolemioClient("  my-token\n", http);

        await client.GetAirQualityIndexTypesAsync();

        Assert.Equal(new Uri("https://api.golemio.cz/v2/airqualitystations/indextypes"), http.Requests[0].RequestUri);
        Assert.Equal(["my-token"], http.Requests[0].Headers.GetValues("X-Access-Token"));
    }

    [Fact]
    public void A_token_that_cannot_be_a_header_is_reported_as_unauthorized()
    {
        var e = Assert.Throws<GolemioException>(() => new GolemioClient("line one\nline two"));

        Assert.Equal(GolemioError.Unauthorized, e.Error);
    }

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized, GolemioError.Unauthorized)]
    [InlineData(HttpStatusCode.Forbidden, GolemioError.Forbidden)]
    [InlineData(HttpStatusCode.NotFound, GolemioError.NotFound)]
    [InlineData(HttpStatusCode.TooManyRequests, GolemioError.RateLimited)]
    [InlineData(HttpStatusCode.BadRequest, GolemioError.Unexpected)]
    [InlineData(HttpStatusCode.InternalServerError, GolemioError.Unexpected)]
    public async Task Failed_statuses_become_errors_that_quote_the_response(HttpStatusCode status, GolemioError expected)
    {
        using var client = new GolemioClient("token", StubHandler.Returning("""{"error_message":"Nope","error_status":0}""", status));

        var e = await Assert.ThrowsAsync<GolemioException>(() => client.GetAirQualityIndexTypesAsync());

        Assert.Equal(expected, e.Error);
        Assert.Contains($"returned {(int)status}", e.Message);
        Assert.Contains("Nope", e.Message);
    }

    [Fact]
    public async Task A_connection_failure_is_a_network_error()
    {
        using var client = new GolemioClient("token", new StubHandler(_ => throw new HttpRequestException("No such host")));

        var e = await Assert.ThrowsAsync<GolemioException>(() => client.GetAirQualityIndexTypesAsync());

        Assert.Equal(GolemioError.Network, e.Error);
    }

    [Theory]
    [InlineData("<html>gateway timeout</html>")]
    [InlineData("""{"not":"a list"}""")]
    [InlineData("null")]
    public async Task A_body_of_the_wrong_shape_is_an_unexpected_error(string body)
    {
        using var client = new GolemioClient("token", StubHandler.Returning(body));

        var e = await Assert.ThrowsAsync<GolemioException>(() => client.GetAirQualityIndexTypesAsync());

        Assert.Equal(GolemioError.Unexpected, e.Error);
    }

    [Fact]
    public async Task Cancellation_is_not_dressed_up_as_a_Golemio_error()
    {
        using var client = new GolemioClient("token", StubHandler.Returning("[]"));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => client.GetAirQualityIndexTypesAsync(new CancellationToken(canceled: true)));
    }

    [Fact]
    public void Queries_skip_nulls_repeat_keys_and_ignore_the_current_culture()
    {
        var previous = CultureInfo.CurrentCulture;
        CultureInfo.CurrentCulture = new CultureInfo("cs-CZ");
        try
        {
            var query = new Query
            {
                { "range", 1.5 },
                { "limit", (int?)null },
                { "onlyMonitored", true },
                { "from", new DateTimeOffset(2026, 10, 5, 10, 30, 0, TimeSpan.FromHours(2)) },
                { "ids[]", new[] { "U1 Z", "U2" } },
            };

            Assert.Equal("range=1.5&onlyMonitored=true&from=2026-10-05T08%3A30%3A00Z&ids%5B%5D=U1%20Z&ids%5B%5D=U2", query.ToString());
        }
        finally
        {
            CultureInfo.CurrentCulture = previous;
        }
    }
}
