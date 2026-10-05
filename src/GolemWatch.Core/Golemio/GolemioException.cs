namespace GolemWatch.Core.Golemio;

public enum GolemioError
{
    /// <summary>The token is missing or wrong (HTTP 401).</summary>
    Unauthorized,
    /// <summary>The token is valid but has no access to this dataset (HTTP 403).</summary>
    Forbidden,
    NotFound,
    RateLimited,
    Network,
    Unexpected,
}

public sealed class GolemioException(GolemioError error, string message, Exception? inner = null)
    : Exception(message, inner)
{
    public GolemioError Error { get; } = error;
}
