using System.Collections;
using System.Globalization;

namespace GolemWatch.Core.Golemio;

/// <summary>Query string builder; null values are skipped and keys may repeat (<c>ids[]</c>).</summary>
internal sealed class Query : IEnumerable<KeyValuePair<string, string>>
{
    private readonly List<KeyValuePair<string, string>> _items = [];

    public void Add(string key, object? value)
    {
        if (value is not null)
            _items.Add(new(key, Format(value)));
    }

    public void Add(string key, IEnumerable<string> values)
    {
        foreach (var value in values)
            _items.Add(new(key, value));
    }

    public override string ToString() =>
        string.Join('&', _items.Select(p => $"{Uri.EscapeDataString(p.Key)}={Uri.EscapeDataString(p.Value)}"));

    public IEnumerator<KeyValuePair<string, string>> GetEnumerator() => _items.GetEnumerator();

    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();

    private static string Format(object value) => value switch
    {
        string s => s,
        bool b => b ? "true" : "false",
        DateTimeOffset d => d.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture),
        IFormattable f => f.ToString(null, CultureInfo.InvariantCulture),
        _ => value.ToString() ?? "",
    };
}
