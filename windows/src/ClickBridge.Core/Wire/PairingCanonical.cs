using System.Text.RegularExpressions;

namespace ClickBridge.Core.Wire;

/// <summary>
/// Shared canonical-encoding rules used by both WireCodec (field validation)
/// and PairingLink (invitation URL construction) — consolidated here rather
/// than duplicated per call site the way WireMessage.swift's
/// PairingWireEncoding and PairingController.swift's PairingLink each
/// re-implement the same base64url/regex checks independently.
/// </summary>
internal static partial class PairingCanonical
{
    [GeneratedRegex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")]
    private static partial Regex UuidPattern();

    [GeneratedRegex("^[0-9a-f]{64}$")]
    private static partial Regex TokenPattern();

    [GeneratedRegex("^[0-9]{3} [0-9]{3}$")]
    private static partial Regex ConfirmationCodePattern();

    public static bool IsUuid(string value) => UuidPattern().IsMatch(value);
    public static bool IsToken(string value) => TokenPattern().IsMatch(value);
    public static bool IsConfirmationCode(string value) => ConfirmationCodePattern().IsMatch(value);

    /// <summary>
    /// 43-character unpadded base64url encoding of exactly 32 bytes, and
    /// only in its canonical (non-alternate) form — mirrors
    /// isCanonicalPairingReference in both Swift files it was ported from.
    /// </summary>
    public static bool IsCanonicalReference(string value)
    {
        if (value.Length != 43)
        {
            return false;
        }
        foreach (var ch in value)
        {
            var isAllowed = (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') ||
                             (ch >= '0' && ch <= '9') || ch == '-' || ch == '_';
            if (!isAllowed)
            {
                return false;
            }
        }
        var standard = value.Replace('-', '+').Replace('_', '/') + "=";
        byte[] decoded;
        try
        {
            decoded = Convert.FromBase64String(standard);
        }
        catch (FormatException)
        {
            return false;
        }
        if (decoded.Length != 32)
        {
            return false;
        }
        return ToCanonicalReference(decoded) == value;
    }

    public static string ToCanonicalReference(byte[] thirtyTwoBytes) =>
        Convert.ToBase64String(thirtyTwoBytes)
            .Replace('+', '-')
            .Replace('/', '_')
            .TrimEnd('=');
}
