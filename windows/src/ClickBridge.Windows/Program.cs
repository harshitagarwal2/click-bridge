using ClickBridge.Core.Actions;
using ClickBridge.Core.Relay;
using ClickBridge.Core.Storage;
using ClickBridge.Windows.Input;
using ClickBridge.Windows.Storage;

namespace ClickBridge.Windows;

/// <summary>Port of the @main ClickBridgeApp.init() wiring in mac/ClickBridgeMac/ClickBridgeApp.swift.</summary>
internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();

        var defaults = new JsonFileKeyValueStore();
        // Unlike Swift's throwing init (which forces two separate call-site
        // branches), SettingsStore already fails closed internally and
        // records the failure in StorageError — see its doc comment.
        var settings = new SettingsStore(defaults, new DpapiSecretStore());
        var startupNotice = settings.StorageError;

        var permission = new WindowsInputPermissionService();
        var poster = new WindowsInputExecutor();
        var processor = new ActionProcessor(poster, permission);
        var client = new RelayClient(processor, processor);
        var appState = new AppState(settings, client, processor, permission, startupNotice);

        Application.Run(new TrayApplicationContext(appState));
    }
}
