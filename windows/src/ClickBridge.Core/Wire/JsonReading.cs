using System.Text.Json;

namespace ClickBridge.Core.Wire;

/// <summary>
/// Field readers used while validating and constructing a WireMessage from a
/// parsed JSON object. Every method throws WireException(InvalidValue) on a
/// missing or wrong-shaped field, mirroring the strict, no-coercion style of
/// mac/ClickBridgeMac/StrictWireDecoder.swift.
/// </summary>
internal static class JsonReading
{
    public static string GetString(JsonElement obj, string key)
    {
        if (!obj.TryGetProperty(key, out var value) || value.ValueKind != JsonValueKind.String)
        {
            throw WireException.InvalidValue();
        }
        return value.GetString()!;
    }

    public static bool GetBool(JsonElement obj, string key)
    {
        if (!obj.TryGetProperty(key, out var value) ||
            value.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            throw WireException.InvalidValue();
        }
        return value.GetBoolean();
    }

    public static double GetNumber(JsonElement obj, string key)
    {
        if (!obj.TryGetProperty(key, out var value) || value.ValueKind != JsonValueKind.Number)
        {
            throw WireException.InvalidValue();
        }
        return value.GetDouble();
    }

    public static int GetNonNegativeInteger(JsonElement obj, string key)
    {
        var value = GetNumber(obj, key);
        if (value < 0 || Math.Truncate(value) != value || value > int.MaxValue)
        {
            throw WireException.InvalidValue();
        }
        return (int)value;
    }

    public static long GetSafeNonNegativeInteger(JsonElement obj, string key)
    {
        var value = GetNumber(obj, key);
        if (value < 0 || Math.Truncate(value) != value || value > Constants.MaximumSafeInteger)
        {
            throw WireException.InvalidValue();
        }
        return (long)value;
    }

    public static void RequirePositiveInteger(JsonElement obj, string key)
    {
        if (GetSafeNonNegativeInteger(obj, key) <= 0)
        {
            throw WireException.InvalidValue();
        }
    }

    public static void RequirePairingVersion(JsonElement obj)
    {
        if (GetSafeNonNegativeInteger(obj, "pairingVersion") != Constants.PairingVersion)
        {
            throw WireException.InvalidValue();
        }
    }

    public static void RequireOneOf(string value, params string[] allowed)
    {
        if (Array.IndexOf(allowed, value) < 0)
        {
            throw WireException.InvalidValue();
        }
    }

    public static string RequireUuid(JsonElement obj, string key)
    {
        var value = GetString(obj, key);
        if (!PairingCanonical.IsUuid(value))
        {
            throw WireException.InvalidValue();
        }
        return value;
    }

    public static PermissionState RequirePermission(JsonElement obj)
    {
        var value = GetString(obj, "permission");
        if (!PermissionStateWire.TryFromWire(value, out var permission))
        {
            throw WireException.InvalidValue();
        }
        return permission;
    }

    /// <summary>
    /// Mirrors StrictWireDecoder.exact: the object's keys must equal
    /// `fields` exactly — no missing keys, no extras.
    /// </summary>
    public static void RequireExactFields(JsonElement obj, IReadOnlyCollection<string> fields)
    {
        var expected = new HashSet<string>(fields, StringComparer.Ordinal);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in obj.EnumerateObject())
        {
            seen.Add(property.Name);
            if (!expected.Contains(property.Name))
            {
                throw WireException.UnknownKeys(new[] { property.Name });
            }
        }
        if (!expected.IsSubsetOf(seen))
        {
            throw WireException.InvalidValue();
        }
    }
}
