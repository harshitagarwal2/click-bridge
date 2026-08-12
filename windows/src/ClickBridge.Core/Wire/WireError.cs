namespace ClickBridge.Core.Wire;

/// <summary>Mirrors mac/ClickBridgeMac/WireMessage.swift's WireError.</summary>
public enum WireErrorKind
{
    TooLarge,
    BinaryFrame,
    NotJsonObject,
    MissingType,
    UnsupportedVersion,
    UnknownType,
    UnknownKeys,
    InvalidRole,
    MessageNotAllowed,
    InvalidValue,
    DecodeFailed,
}

public sealed class WireException : Exception
{
    public WireErrorKind Kind { get; }
    public string? Detail { get; }

    public WireException(WireErrorKind kind, string? detail = null)
        : base(detail is null ? kind.ToString() : $"{kind}: {detail}")
    {
        Kind = kind;
        Detail = detail;
    }

    public static WireException TooLarge() => new(WireErrorKind.TooLarge);
    public static WireException BinaryFrame() => new(WireErrorKind.BinaryFrame);
    public static WireException NotJsonObject() => new(WireErrorKind.NotJsonObject);
    public static WireException UnsupportedVersion() => new(WireErrorKind.UnsupportedVersion);
    public static WireException UnknownType(string type) => new(WireErrorKind.UnknownType, type);
    public static WireException UnknownKeys(IEnumerable<string> keys) =>
        new(WireErrorKind.UnknownKeys, string.Join(",", keys));
    public static WireException MessageNotAllowed() => new(WireErrorKind.MessageNotAllowed);
    public static WireException InvalidValue() => new(WireErrorKind.InvalidValue);
    public static WireException DecodeFailed(string type) => new(WireErrorKind.DecodeFailed, type);
}
