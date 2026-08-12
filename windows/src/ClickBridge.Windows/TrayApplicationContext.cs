using ClickBridge.Core.Relay;
using ClickBridge.Core.Wire;

namespace ClickBridge.Windows;

/// <summary>
/// Port of the MenuBarExtra body in mac/ClickBridgeMac/ClickBridgeApp.swift,
/// using NotifyIcon + ContextMenuStrip — the closest Windows analog to a
/// macOS menu-bar-only app (no taskbar window, no Alt-Tab entry).
/// </summary>
public sealed class TrayApplicationContext : ApplicationContext
{
    private readonly AppState _app;
    private readonly System.Threading.SynchronizationContext _uiContext;
    private readonly NotifyIcon _trayIcon;
    private readonly ToolStripMenuItem _connectionItem;
    private readonly ToolStripMenuItem _permissionItem;
    private readonly ToolStripMenuItem _remoteToggleItem;
    private readonly ToolStripMenuItem _lastResultItem;
    private readonly ToolStripMenuItem _noticeItem;
    private SettingsForm? _settingsForm;

    public TrayApplicationContext(AppState app)
    {
        _app = app;
        _uiContext = System.Threading.SynchronizationContext.Current
            ?? new System.Windows.Forms.WindowsFormsSynchronizationContext();

        _connectionItem = new ToolStripMenuItem { Enabled = false };
        _permissionItem = new ToolStripMenuItem { Enabled = false };
        _remoteToggleItem = new ToolStripMenuItem("Remote control enabled") { CheckOnClick = true };
        _remoteToggleItem.Click += (_, _) => _app.SetPersistedRemoteEnabled(_remoteToggleItem.Checked);
        _lastResultItem = new ToolStripMenuItem { Enabled = false };
        _noticeItem = new ToolStripMenuItem { Enabled = false, Visible = false };

        var reconnectItem = new ToolStripMenuItem("Reconnect");
        reconnectItem.Click += (_, _) => _ = _app.ReconnectAsync();

        var settingsItem = new ToolStripMenuItem("Settings…");
        settingsItem.Click += (_, _) => ShowSettings();

        var quitItem = new ToolStripMenuItem("Quit");
        quitItem.Click += (_, _) => Application.Exit();

        var menu = new ContextMenuStrip();
        menu.Items.Add(_connectionItem);
        menu.Items.Add(_permissionItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_remoteToggleItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_lastResultItem);
        menu.Items.Add(_noticeItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(reconnectItem);
        menu.Items.Add(settingsItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(quitItem);

        _trayIcon = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Text = "Click Bridge",
            ContextMenuStrip = menu,
            Visible = true,
        };
        _trayIcon.DoubleClick += (_, _) => ShowSettings();

        _app.Changed += OnAppStateChanged;
        _app.RefreshPermission();
        Refresh();
    }

    private void OnAppStateChanged() => _uiContext.Post(_ => Refresh(), null);

    private void Refresh()
    {
        _connectionItem.Text = _app.Connection switch
        {
            RelayClient.Status.Connected => "Connected",
            RelayClient.Status.Connecting => "Connecting…",
            _ => "Disconnected",
        };
        _permissionItem.Text = _app.Permission == PermissionState.Ready
            ? "Input permission: ready"
            : "Input permission: required";
        _remoteToggleItem.Checked = _app.Settings.RemoteEnabled;
        _lastResultItem.Text = $"Last: {_app.LastResult}";
        if (_app.Notice is { Length: > 0 } notice)
        {
            _noticeItem.Text = notice;
            _noticeItem.Visible = true;
        }
        else
        {
            _noticeItem.Visible = false;
        }
        _settingsForm?.RefreshFromState();
    }

    private void ShowSettings()
    {
        if (_settingsForm is { IsDisposed: false })
        {
            _settingsForm.Activate();
            return;
        }
        _settingsForm = new SettingsForm(_app);
        _settingsForm.FormClosed += (_, _) => _settingsForm = null;
        _settingsForm.Show();
        _settingsForm.Activate();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _app.Changed -= OnAppStateChanged;
            _trayIcon.Visible = false;
            _trayIcon.Dispose();
        }
        base.Dispose(disposing);
    }
}
