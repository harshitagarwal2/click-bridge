using ClickBridge.Core.Wire;

namespace ClickBridge.Core.Relay;

/// <summary>Mirrors mac/ClickBridgeMac/PairingController.swift's PairingTransport protocol.</summary>
public interface IPairingTransport
{
    Task SendPairingAsync(WireMessage message);
}
