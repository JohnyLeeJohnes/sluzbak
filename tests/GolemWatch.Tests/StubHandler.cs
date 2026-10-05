using System.Net;
using System.Text;

namespace GolemWatch.Tests;

/// <summary>Stands in for api.golemio.cz and records what was asked of it.</summary>
internal sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
{
    public List<HttpRequestMessage> Requests { get; } = [];

    /// <summary>Path and query of the only request made, unescaped so that tests stay readable.</summary>
    public string Request => PathAndQuery(Assert.Single(Requests));

    public static StubHandler Returning(string json, HttpStatusCode status = HttpStatusCode.OK) => new(_ => Reply(json, status));

    public static HttpResponseMessage Reply(string json, HttpStatusCode status = HttpStatusCode.OK) =>
        new(status) { Content = new StringContent(json, Encoding.UTF8, "application/json") };

    public static string PathAndQuery(HttpRequestMessage request) => Uri.UnescapeDataString(request.RequestUri!.PathAndQuery);

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Requests.Add(request);
        return Task.FromResult(respond(request));
    }
}
