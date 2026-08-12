using System.Security.Cryptography;
using System.Text;
using ClickBridge.Core.Storage;

namespace ClickBridge.Windows.Storage;

/// <summary>
/// Port of mac/ClickBridgeMac/KeychainStore.swift. DPAPI with CurrentUser
/// scope is the closest Windows analog to a per-user Keychain item: the
/// blob is decryptable only by the same Windows user account on the same
/// machine, with no cross-device sync (Keychain here isn't iCloud-synced
/// either, so this carries no regression).
/// </summary>
public sealed class DpapiSecretStore : ISecretStoring
{
    private readonly string _directory;

    public DpapiSecretStore(string? directory = null)
    {
        _directory = directory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClickBridge");
        Directory.CreateDirectory(_directory);
    }

    private string PathFor(string account) => Path.Combine(_directory, $"{account}.secret");

    public string? Read(string account)
    {
        var path = PathFor(account);
        if (!File.Exists(path))
        {
            return null;
        }
        var protectedBytes = File.ReadAllBytes(path);
        var bytes = ProtectedData.Unprotect(protectedBytes, null, DataProtectionScope.CurrentUser);
        return Encoding.UTF8.GetString(bytes);
    }

    public void Write(string value, string account)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        var protectedBytes = ProtectedData.Protect(bytes, null, DataProtectionScope.CurrentUser);
        File.WriteAllBytes(PathFor(account), protectedBytes);
    }

    public void Delete(string account)
    {
        var path = PathFor(account);
        if (File.Exists(path))
        {
            File.Delete(path);
        }
    }
}
