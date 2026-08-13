using ClickBridge.Core.Pairing;
using ClickBridge.Windows.Pairing;

namespace ClickBridge.Windows;

/// <summary>
/// Port of SettingsView + PairingSettingsView from mac/ClickBridgeMac/ClickBridgeApp.swift:
/// the pairing section (QR / invitation / approval / recovery) plus the
/// collapsible "Advanced legacy connection" fields (relay URL, MAC_TOKEN).
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
    private readonly Button _pairButton = new() { Text = "Pair Phone", AutoSize = true };
    private readonly Button _recoveryButton = new() { Visible = false, AutoSize = true };

    private readonly CheckBox _advancedToggle = new() { Text = "Advanced legacy connection", AutoSize = true };
    private readonly Panel _advancedPanel = new() { Visible = false, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink };
    private readonly TextBox _relayUrlBox = new() { Width = 360, PlaceholderText = "wss://your-host/ws" };
    private readonly TextBox _tokenBox = new() { Width = 360, UseSystemPasswordChar = true };
    private readonly Button _saveTokenButton = new() { Text = "Save", AutoSize = true };
    private readonly Button _clearTokenButton = new() { Text = "Clear", AutoSize = true };
    private readonly Label _tokenStatusLabel = new() { AutoSize = true };
    private readonly Label _storageErrorLabel = new() { AutoSize = true, ForeColor = Color.Firebrick };

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

        _advancedPanel.Controls.Add(BuildAdvancedLayout());

        root.Controls.Add(phoneGroup);
        root.Controls.Add(_advancedToggle);
        root.Controls.Add(_advancedPanel);
        Controls.Add(root);

        _advancedToggle.CheckedChanged += (_, _) => _advancedPanel.Visible = _advancedToggle.Checked;
        _pairButton.Click += OnPairButtonClicked;
        _copyInvitationButton.Click += (_, _) => CopyCurrentInvitation();
        _copyPwaInvitationButton.Click += (_, _) => CopyPwaInvitation();
        _cancelInvitationButton.Click += (_, _) => _ = _subscribedPairing?.CancelAsync();
        _recoveryButton.Click += (_, _) => _ = _subscribedPairing?.RegenerateAsync();
        _saveTokenButton.Click += OnSaveTokenClicked;
        _clearTokenButton.Click += (_, _) => _ = _app.ClearTokenAsync();

        RefreshFromState();
    }

    private TableLayoutPanel BuildAdvancedLayout()
    {
        var layout = new TableLayoutPanel { ColumnCount = 2, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink };
        layout.Controls.Add(new Label { Text = "Relay URL", AutoSize = true }, 0, 0);
        layout.Controls.Add(_relayUrlBox, 1, 0);
        layout.Controls.Add(new Label { Text = "Mac token", AutoSize = true }, 0, 1);
        layout.Controls.Add(_tokenBox, 1, 1);
        var tokenButtons = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        tokenButtons.Controls.Add(_saveTokenButton);
        tokenButtons.Controls.Add(_clearTokenButton);
        layout.Controls.Add(tokenButtons, 1, 2);
        layout.Controls.Add(_tokenStatusLabel, 1, 3);
        layout.Controls.Add(_storageErrorLabel, 1, 4);
        _relayUrlBox.Leave += (_, _) => _app.Settings.RelayUrlString = _relayUrlBox.Text;
        return layout;
    }

    public void RefreshFromState()
    {
        if (!string.Equals(_relayUrlBox.Text, _app.Settings.RelayUrlString, StringComparison.Ordinal) && !_relayUrlBox.Focused)
        {
            _relayUrlBox.Text = _app.Settings.RelayUrlString;
        }
        _tokenStatusLabel.Text = _app.Settings.HasToken ? "A token is stored." : "No token stored.";
        _storageErrorLabel.Text = _app.Settings.StorageError ?? "";
        _storageErrorLabel.Visible = _app.Settings.StorageError is { Length: > 0 };

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
            PairingState.Ready => "Ready to pair a phone.",
            PairingState.ReplacementConfirmation => "Confirm phone replacement to continue.",
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
        if (_app.PairingAction.RequiresReplacementConfirmation)
        {
            var confirmed = MessageBox.Show(
                this,
                "The currently enrolled phone will stop working after the new phone is approved.",
                "Replace the paired phone?",
                MessageBoxButtons.OKCancel,
                MessageBoxIcon.Warning) == DialogResult.OK;
            if (!confirmed) return;
            _app.ConfirmReplacement();
        }
        else
        {
            _app.BeginPairing();
        }
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

    private void OnSaveTokenClicked(object? sender, EventArgs e)
    {
        var normalized = _tokenBox.Text.Trim().ToLowerInvariant();
        if (normalized.Length != 64 || !normalized.All(Uri.IsHexDigit))
        {
            MessageBox.Show(this, "MAC_TOKEN must be exactly 64 lowercase hexadecimal characters.", "Invalid token",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        _ = _app.SaveTokenAsync(normalized);
        _tokenBox.Text = "";
    }
}
