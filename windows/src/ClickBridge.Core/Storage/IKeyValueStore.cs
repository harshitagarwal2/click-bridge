namespace ClickBridge.Core.Storage;

/// <summary>Stands in for UserDefaults — Windows implements this with a small JSON settings file.</summary>
public interface IKeyValueStore
{
    string? GetString(string key);
    void SetString(string key, string value);
    bool? GetBool(string key);
    void SetBool(string key, bool value);
}
