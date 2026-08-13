using ClickBridge.Core.Pairing;

namespace ClickBridge.Windows;

/// <summary>Port of PairingApprovalView from mac/ClickBridgeMac/ClickBridgeApp.swift.</summary>
public sealed class PairingApprovalDialog : Form
{
    private readonly Action _approve;
    private readonly Action _deny;
    private readonly Label _codeLabel;

    public PairingApprovalDialog(PairingApproval approval, Action approve, Action deny)
    {
        _approve = approve;
        _deny = deny;

        Text = "Confirm Phone Pairing";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterParent;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(20);

        var layout = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.TopDown, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, WrapContents = false,
        };
        layout.Controls.Add(new Label { Text = "Confirm this code matches the phone", AutoSize = true, Font = new Font(Font, FontStyle.Bold) });
        _codeLabel = new Label { Text = approval.ConfirmationCode, AutoSize = true, Font = new Font("Consolas", 20) };
        layout.Controls.Add(_codeLabel);

        var buttons = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        var approveButton = new Button { Text = "Approve", AutoSize = true };
        approveButton.Click += (_, _) => { _approve(); Close(); };
        var denyButton = new Button { Text = "Deny", AutoSize = true };
        denyButton.Click += (_, _) => { _deny(); Close(); };
        buttons.Controls.Add(approveButton);
        buttons.Controls.Add(denyButton);
        layout.Controls.Add(buttons);

        Controls.Add(layout);
        FormClosing += (_, e) =>
        {
            // Closing without an explicit choice (e.g. the invitation
            // expired underneath the dialog) counts as a deny — mirrors the
            // SwiftUI sheet's onDismiss-triggers-deny binding.
            if (e.CloseReason == CloseReason.UserClosing)
            {
                _deny();
            }
        };
    }

    public void UpdateApproval(PairingApproval approval)
    {
        _codeLabel.Text = approval.ConfirmationCode;
    }
}
