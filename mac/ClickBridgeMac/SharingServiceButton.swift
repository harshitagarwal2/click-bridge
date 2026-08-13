import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum PairingShareProviderError: Error, LocalizedError, Equatable {
    case invitationUnavailable

    var errorDescription: String? {
        "This invitation is no longer available. Create a new one."
    }
}

@MainActor
enum PairingShareProviderFactory {
    static func prepare(
        resolver: @escaping PairingInvitationURLResolver,
        unavailable: @escaping @MainActor () -> Void = {}
    ) -> NSItemProvider? {
        guard resolver() != nil else {
            unavailable()
            return nil
        }

        let provider = NSItemProvider()
        register(type: .url, on: provider, resolver: resolver, unavailable: unavailable)
        register(type: .plainText, on: provider, resolver: resolver, unavailable: unavailable)
        provider.suggestedName = "Click Bridge pairing invitation"
        return provider
    }

    private static func register(
        type: UTType,
        on provider: NSItemProvider,
        resolver: @escaping PairingInvitationURLResolver,
        unavailable: @escaping @MainActor () -> Void
    ) {
        provider.registerDataRepresentation(
            forTypeIdentifier: type.identifier,
            visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 1)
            Task { @MainActor in
                guard !progress.isCancelled, let url = resolver() else {
                    unavailable()
                    completion(nil, PairingShareProviderError.invitationUnavailable)
                    return
                }
                completion(Data(url.absoluteString.utf8), nil)
                progress.completedUnitCount = 1
            }
            return progress
        }
    }
}

struct SharingServiceButton: NSViewRepresentable {
    let resolver: PairingInvitationURLResolver
    let feedback: @MainActor (PairingFeedback) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(resolver: resolver, feedback: feedback)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: "Share Secure Setup Link…",
            target: context.coordinator,
            action: #selector(Coordinator.presentPicker(_:))
        )
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.setButtonType(.momentaryPushIn)
        button.identifier = NSUserInterfaceItemIdentifier(PairingAccessibility.share)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.resolver = resolver
        context.coordinator.feedback = feedback
        button.isEnabled = resolver() != nil
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency NSSharingServicePickerDelegate {
        var resolver: PairingInvitationURLResolver
        var feedback: @MainActor (PairingFeedback) -> Void
        private var picker: NSSharingServicePicker?
        private var provider: NSItemProvider?

        init(
            resolver: @escaping PairingInvitationURLResolver,
            feedback: @escaping @MainActor (PairingFeedback) -> Void
        ) {
            self.resolver = resolver
            self.feedback = feedback
        }

        @objc func presentPicker(_ sender: NSButton) {
            guard let provider = PairingShareProviderFactory.prepare(
                resolver: resolver,
                unavailable: { [weak self] in self?.feedback(.invitationUnavailable) }
            ) else { return }

            let picker = NSSharingServicePicker(items: [provider])
            picker.delegate = self
            self.provider = provider
            self.picker = picker
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }

        func sharingServicePicker(
            _ sharingServicePicker: NSSharingServicePicker,
            didChoose service: NSSharingService?
        ) {
            if service != nil { feedback(.shareStarted) }
        }
    }
}
