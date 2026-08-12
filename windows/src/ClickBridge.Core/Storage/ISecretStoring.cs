namespace ClickBridge.Core.Storage;

/// <summary>
/// Port of mac/ClickBridgeMac/KeychainStore.swift's SecretStoring protocol.
/// Windows implements this with DPAPI (see ClickBridge.Windows/Storage/DpapiSecretStore.cs);
/// the Mac implements it with Keychain Services.
/// </summary>
public interface ISecretStoring
{
    string? Read(string account);
    void Write(string value, string account);
    void Delete(string account);
}

/// <summary>Fail-closed stand-in used once the real secret store has proven unavailable — mirrors UnavailableSecretStore.</summary>
public sealed class UnavailableSecretStore(Exception failure) : ISecretStoring
{
    private readonly Exception _failure = failure;

    public string? Read(string account) => throw _failure;
    public void Write(string value, string account) => throw _failure;
    public void Delete(string account) => throw _failure;
}
