namespace ClickBridge.Core.Storage;

/// <summary>
/// Port of mac/ClickBridgeMac/SettingsStore.swift. Swift models "secret
/// store failed at startup" as two different init paths that permanently
/// swap in an UnavailableSecretStore; here a single constructor does the
/// same swap internally the first time Read() throws, which produces the
/// identical fail-closed-for-the-rest-of-the-session behavior with one
/// code path instead of two.
/// </summary>
public sealed class SettingsStore
{
    public const string RelayUrlKey = "relayURL";
    public const string RemoteEnabledKey = "remoteEnabled";
    private const string MacTokenAccount = "macToken";

    private readonly IKeyValueStore _defaults;
    private ISecretStoring _secrets;

    private string _relayUrlString;
    private bool _remoteEnabled;

    public string RelayUrlString
    {
        get => _relayUrlString;
        set
        {
            _relayUrlString = value;
            _defaults.SetString(RelayUrlKey, value);
            Changed?.Invoke();
        }
    }

    public bool RemoteEnabled
    {
        get => _remoteEnabled;
        set
        {
            _remoteEnabled = value;
            _defaults.SetBool(RemoteEnabledKey, value);
            Changed?.Invoke();
        }
    }

    public bool HasToken { get; private set; }
    public string? StorageError { get; private set; }

    public event Action? Changed;

    public SettingsStore(IKeyValueStore defaults, ISecretStoring secrets)
    {
        _defaults = defaults;
        _secrets = secrets;
        _relayUrlString = defaults.GetString(RelayUrlKey) ?? "";
        _remoteEnabled = defaults.GetBool(RemoteEnabledKey) ?? false;
        try
        {
            HasToken = !string.IsNullOrEmpty(secrets.Read(MacTokenAccount));
        }
        catch (Exception ex)
        {
            _secrets = new UnavailableSecretStore(ex);
            HasToken = false;
            StorageError = $"Secret store is unavailable: {ex.Message}";
        }
    }

    public string? MacToken()
    {
        try
        {
            return _secrets.Read(MacTokenAccount);
        }
        catch (Exception ex)
        {
            StorageError = $"Could not read MAC_TOKEN: {ex.Message}";
            throw;
        }
    }

    public void SaveMacToken(string value)
    {
        try
        {
            _secrets.Write(value, MacTokenAccount);
            HasToken = true;
            StorageError = null;
        }
        catch (Exception ex)
        {
            StorageError = $"Could not save MAC_TOKEN: {ex.Message}";
            throw;
        }
        Changed?.Invoke();
    }

    public void ClearMacToken()
    {
        try
        {
            _secrets.Delete(MacTokenAccount);
            HasToken = false;
            StorageError = null;
        }
        catch (Exception ex)
        {
            StorageError = $"Could not clear MAC_TOKEN: {ex.Message}";
            throw;
        }
        Changed?.Invoke();
    }

    public void SaveEnrollment(string relayUrl, string token)
    {
        SaveMacToken(token);
        RelayUrlString = relayUrl;
    }
}
