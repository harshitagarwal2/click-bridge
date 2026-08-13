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

        root.Controls.Add(phoneGroup);
        Controls.Add(root);

        _pairButton.Click += OnPairButtonClicked;
        _copyInvitationButton.Click += (_, _) => CopyCurrentInvitation();
        _copyPwaInvitationButton.Click += (_, _) => CopyPwaInvitation();
        _cancelInvitationButton.Click += (_, _) => _ = _subscribedPairing?.CancelAsync();
        _recoveryButton.Click += (_, _) => _ = _subscribedPairing?.RegenerateAsync();
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

}
