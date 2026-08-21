using ClickBridge.Core.Pairing;
using ClickBridge.Windows.Pairing;

namespace ClickBridge.Windows;

/// <summary>
/// Port of SettingsView + PairingSettingsView from mac/ClickBridgeMac/ClickBridgeApp.swift:
/// the pairing section (QR / invitation / approval / recovery). Relay
/// enrollment and credentials are managed internally by the app.
/// </summary>
public sealed class SettingsForm : Form
{
    private readonly AppState _app;
    private PairingController? _subscribedPairing;
    private PairingApprovalDialog? _approvalDialog;

    private readonly Label _pairingStatusLabel = new() { AutoSize = true, MaximumSize = new Size(420, 0) };
    private readonly PictureBox _qrBox = new() { Size = new Size(208, 208), SizeMode = PictureBoxSizeMode.Zoom, Visible = false };
    private readonly Button _copyInvitationButton = new() { Text = "Copy Invitation", Visible = false, AutoSize = true };
    private readonly Button _copyPwaInvitationButton = new() { Text = "Copy PWA Invitation", Visible = false, AutoSize = true };
    private readonly Button _cancelInvitationButton = new() { Text = "Cancel", Visible = false, AutoSize = true };
    private readonly Button _pairButton = new() { Text = "Add Phone", AutoSize = true };
    private readonly Button _recoveryButton = new() { Visible = false, AutoSize = true };

    // Multi-desktop fan-out: allow this Windows PC to join the SAME bridge (same relay URL + token)
    // as your Mac(s). A single iPhone click then fans out to all desktops on that bridge.
    private readonly TextBox _relayUrlBox = new() { Width = 400, PlaceholderText = "wss://your-host/ws/xxxxxxxxxxxxxxxxxxxxxx" };
    private readonly TextBox _tokenBox = new() { Width = 400, PlaceholderText = "64 hex characters (leave blank to keep stored token)", UseSystemPasswordChar = true };
    private readonly Label _connectionFeedbackLabel = new() { AutoSize = true, MaximumSize = new Size(420, 0), ForeColor = SystemColors.GrayText };
    private readonly Button _saveConnectionButton = new() { Text = "Save & Reconnect", AutoSize = true };
    private readonly Button _copyConnectionButton = new() { Text = "Copy Relay URL", AutoSize = true };
    private readonly CheckBox _showTokenBox = new() { Text = "Show token", AutoSize = true };

    public SettingsForm(AppState app)
    {
        _app = app;
        Text = "Click Bridge Settings";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(16);

        var root = new TableLayoutPanel { ColumnCount = 1, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink };

        var phoneGroup = new GroupBox { Text = "Phone", AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Width = 440 };
        var phoneLayout = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.TopDown, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, WrapContents = false,
        };
        var invitationButtons = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        invitationButtons.Controls.Add(_copyInvitationButton);
        invitationButtons.Controls.Add(_copyPwaInvitationButton);
        invitationButtons.Controls.Add(_cancelInvitationButton);

        phoneLayout.Controls.Add(_pairingStatusLabel);
        phoneLayout.Controls.Add(_qrBox);
        phoneLayout.Controls.Add(invitationButtons);
        phoneLayout.Controls.Add(_pairButton);
        phoneLayout.Controls.Add(_recoveryButton);
        phoneGroup.Controls.Add(phoneLayout);

        // Connection group for multi-desktop fan-out
        var connectionGroup = new GroupBox { Text = "Connection (for multi-desktop fan-out)", AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Width = 440 };
        var connectionLayout = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, WrapContents = false };
        var urlRow = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        urlRow.Controls.Add(new Label { Text = "Relay URL:", AutoSize = true, TextAlign = ContentAlignment.MiddleLeft });
        urlRow.Controls.Add(_relayUrlBox);
        var tokenRow = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        tokenRow.Controls.Add(new Label { Text = "Mac token:", AutoSize = true });
        tokenRow.Controls.Add(_tokenBox);
        tokenRow.Controls.Add(_showTokenBox);
        var connectionButtons = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        connectionButtons.Controls.Add(_saveConnectionButton);
        connectionButtons.Controls.Add(_copyConnectionButton);
        var hint = new Label { Text = "Use the SAME Relay URL + token on every Mac and this Windows PC to receive the same iPhone click. Copy the Relay URL from your first Mac's Settings → Advanced Connection.", AutoSize = true, MaximumSize = new Size(420, 0), ForeColor = SystemColors.GrayText };
        connectionLayout.Controls.Add(urlRow);
        connectionLayout.Controls.Add(tokenRow);
        connectionLayout.Controls.Add(connectionButtons);
        connectionLayout.Controls.Add(_connectionFeedbackLabel);
        connectionLayout.Controls.Add(hint);
        connectionGroup.Controls.Add(connectionLayout);

        root.Controls.Add(connectionGroup);
        root.Controls.Add(phoneGroup);
        Controls.Add(root);

        _pairButton.Click += OnPairButtonClicked;
        _copyInvitationButton.Click += (_, _) => CopyCurrentInvitation();
        _copyPwaInvitationButton.Click += (_, _) => CopyPwaInvitation();
        _cancelInvitationButton.Click += (_, _) => _ = _subscribedPairing?.CancelAsync();
        _recoveryButton.Click += (_, _) => _ = _subscribedPairing?.RegenerateAsync();
        _copyConnectionButton.Click += (_, _) => { if (!string.IsNullOrWhiteSpace(_app.Settings.RelayUrlString)) Clipboard.SetText(_app.Settings.RelayUrlString); };
        _saveConnectionButton.Click += async (_, _) => await SaveConnectionAsync();
        _showTokenBox.CheckedChanged += (_, _) => _tokenBox.UseSystemPasswordChar = !_showTokenBox.Checked;
        _relayUrlBox.Text = _app.Settings.RelayUrlString;
        _app.Changed += () => BeginInvoke(() => { _relayUrlBox.Text = _app.Settings.RelayUrlString; _connectionFeedbackLabel.Text = _app.Notice ?? ""; });
        RefreshFromState();
    }

    public void RefreshFromState()
    {
        _pairButton.Text = _app.PairingAction.Title;
        _pairButton.Enabled = _app.Pairing?.State is PairingState.Ready;
        _pairButton.Visible = _app.Pairing is not null;

        RewirePairingSubscription();
        RefreshPairingSection();
    }

    private void RewirePairingSubscription()
    {
        if (ReferenceEquals(_subscribedPairing, _app.Pairing)) return;
        if (_subscribedPairing is not null)
        {
            _subscribedPairing.StateChanged -= OnPairingStateChanged;
        }
        _subscribedPairing = _app.Pairing;
        if (_subscribedPairing is not null)
        {
            _subscribedPairing.StateChanged += OnPairingStateChanged;
        }
    }

    private void OnPairingStateChanged() => BeginInvoke(RefreshPairingSection);

    private void RefreshPairingSection()
    {
        var state = _app.Pairing?.State;
        _qrBox.Visible = false;
        _copyInvitationButton.Visible = false;
        _copyPwaInvitationButton.Visible = false;
        _cancelInvitationButton.Visible = false;
        _recoveryButton.Visible = false;

        _pairingStatusLabel.Text = state switch
        {
            null => "Connect this Mac to the relay before pairing a phone.",
            PairingState.Unavailable => "Pairing is unavailable on this connection.",
            PairingState.CheckingStatus => "Checking phone enrollment…",
            PairingState.Ready => "Ready to add a phone.",
            PairingState.ReplacementConfirmation => "Ready to add a phone.",
            PairingState.Creating => "Creating invitation…",
            PairingState.InvitationState => "Scan with the phone you want to pair.",
            PairingState.ApprovalState => "Review the confirmation code.",
            PairingState.Approving => "Approving phone…",
            PairingState.Denying => "Denying phone…",
            PairingState.Cancelling => "Cancelling invitation…",
            PairingState.CancelFailed => "The invitation could not be cancelled safely.",
            PairingState.Completed => "Phone paired.",
            PairingState.Denied => "Phone pairing denied.",
            PairingState.Expired => "The pairing invitation expired.",
            PairingState.Failed => "Pairing failed.",
            _ => "",
        };

        if (state is PairingState.InvitationState invitation)
        {
            var image = QrCodeRenderer.Image(invitation.Invitation.Url);
            _qrBox.Image = image;
            _qrBox.Visible = image is not null;
            _copyInvitationButton.Visible = true;
            _copyPwaInvitationButton.Visible = true;
            _cancelInvitationButton.Visible = true;
        }

        if (_app.Pairing is { } pairing &&
            state is PairingState.CancelFailed or PairingState.Denied or PairingState.Expired or PairingState.Failed &&
            pairing.RecoveryAction is { } action)
        {
            _recoveryButton.Text = action == PairingRecoveryAction.StartAgain ? "Start Again" : "Retry";
            _recoveryButton.Visible = true;
        }

        if (state is PairingState.ApprovalState approval)
        {
            ShowApprovalDialog(approval.Approval);
        }
        else
        {
            _approvalDialog?.Close();
        }
    }

    private void ShowApprovalDialog(PairingApproval approval)
    {
        if (_approvalDialog is { IsDisposed: false })
        {
            _approvalDialog.UpdateApproval(approval);
            return;
        }
        _approvalDialog = new PairingApprovalDialog(approval,
            approve: () => _ = _subscribedPairing?.ApproveAsync(),
            deny: () => _ = _subscribedPairing?.DenyAsync());
        _approvalDialog.FormClosed += (_, _) => _approvalDialog = null;
        _approvalDialog.Show(this);
    }

    private async void OnPairButtonClicked(object? sender, EventArgs e)
    {
        _app.BeginPairing();
        await Task.CompletedTask;
    }

    private void CopyCurrentInvitation()
    {
        if (_app.Pairing?.State is not PairingState.InvitationState invitation) return;
        Clipboard.SetText(invitation.Invitation.SharePayload);
    }

    private void CopyPwaInvitation()
    {
        if (_app.Pairing is not { } pairing || pairing.State is not PairingState.InvitationState invitation) return;
        pairing.CopyWebInvitation(invitation.Invitation, new WindowsClipboard());
    }

    private async Task SaveConnectionAsync()
    {
        var url = _relayUrlBox.Text.Trim();
        var tokenInput = _tokenBox.Text.Trim().ToLowerInvariant();
        if (string.IsNullOrWhiteSpace(url))
        {
            _connectionFeedbackLabel.Text = "Enter a relay URL (wss://host/ws/...).";
            return;
        }
        try { ClickBridge.Core.Relay.RelayEndpoint.Validated(url, allowLocalSimulator: false); }
        catch { _connectionFeedbackLabel.Text = "Invalid relay URL. Must be wss://host/ws or wss://host/ws/<id>."; return; }
        string tokenToSave = tokenInput;
        if (string.IsNullOrEmpty(tokenInput))
        {
            try
            {
                var existing = _app.Settings.MacToken();
                if (string.IsNullOrEmpty(existing)) { _connectionFeedbackLabel.Text = "No stored token. Enter a 64-char hex token."; return; }
                tokenToSave = existing;
            }
            catch (Exception ex) { _connectionFeedbackLabel.Text = ex.Message; return; }
        }
        else
        {
            if (tokenToSave.Length != 64 || !System.Text.RegularExpressions.Regex.IsMatch(tokenToSave, "^[0-9a-f]{64}$"))
            { _connectionFeedbackLabel.Text = "Token must be 64 lowercase hex characters."; return; }
        }
        try
        {
            _app.Settings.SaveEnrollment(url, tokenToSave);
            _connectionFeedbackLabel.Text = "Connection saved. Reconnecting…";
            _tokenBox.Text = "";
            await _app.ReconnectAsync();
            _connectionFeedbackLabel.Text = _app.Notice ?? "Reconnecting…";
        }
        catch (Exception ex) { _connectionFeedbackLabel.Text = ex.Message; }
    }

}
