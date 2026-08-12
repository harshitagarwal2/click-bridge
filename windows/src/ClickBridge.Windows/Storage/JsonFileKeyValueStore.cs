using System.Text.Json;
using ClickBridge.Core.Storage;

namespace ClickBridge.Windows.Storage;

/// <summary>
/// Port of the UserDefaults side of mac/ClickBridgeMac/SettingsStore.swift
/// (relayURL / remoteEnabled only — the token goes through DpapiSecretStore
/// instead). A single small JSON file under %APPDATA%\ClickBridge stands in
/// for UserDefaults' plist-backed preferences domain.
/// </summary>
public sealed class JsonFileKeyValueStore : IKeyValueStore
{
    private readonly string _path;
    private readonly Dictionary<string, JsonElement> _values;
    private readonly object _gate = new();

    public JsonFileKeyValueStore(string? path = null)
    {
        if (path is null)
        {
            var directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ClickBridge");
            Directory.CreateDirectory(directory);
            path = Path.Combine(directory, "settings.json");
        }
        _path = path;
        _values = File.Exists(_path)
            ? JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(File.ReadAllText(_path)) ?? []
            : [];
    }

    public string? GetString(string key) =>
        _values.TryGetValue(key, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    public void SetString(string key, string value) => Set(key, JsonSerializer.SerializeToElement(value));

    public bool? GetBool(string key) =>
        _values.TryGetValue(key, out var value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False
            ? value.GetBoolean()
            : null;

    public void SetBool(string key, bool value) => Set(key, JsonSerializer.SerializeToElement(value));

    private void Set(string key, JsonElement value)
    {
        lock (_gate)
        {
            _values[key] = value;
            File.WriteAllText(_path, JsonSerializer.Serialize(_values));
        }
    }
}
