namespace ClickBridge.Core;

/// <summary>
/// Mirrors mac/ClickBridgeMac/WireMessage.swift's Constants enum and
/// contracts/config/runtime-constants.json. Keep these three in sync by
/// hand until a shared build step asserts them, exactly as the Swift client
/// already does.
/// </summary>
public static class Constants
{
    public const int ProtocolVersion = 1;
    public const int MaxMessageBytes = 4_096;
    public const double ActionLifetimeMs = 2_000;
    public const double ClockSkewToleranceMs = 1_000;
    public const double HeartbeatIntervalSeconds = 20;
    public const double HeartbeatTimeoutSeconds = 10;
    public const double MacReconnectCapSeconds = 5;
    public const double CompletedActionTtlSeconds = 300;
    public const int CompletedActionCap = 4_096;
    public const int ClickGapMs = 0;
    public const int ClickRepetitions = 3;
    public const int PairingVersion = 1;
    public const double PairingTtlSeconds = 300;
    public const int LegacyPhoneCredentialVersion = 0;

    public const long MaximumSafeInteger = 9_007_199_254_740_991;
}
