import AppIntents

struct TriggerClickIntent: AppIntent {
    static var title: LocalizedStringResource = "Trigger Click"
    static var description = IntentDescription("Open Click Bridge and send one click to the connected Mac.")
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        PhoneClickIntentRouter.shared.requestClick()
        return .result(dialog: "Opening Click Bridge.")
    }
}

struct ClickBridgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TriggerClickIntent(),
            phrases: [
                "Trigger a click with \(.applicationName)",
                "Click using \(.applicationName)",
            ],
            shortTitle: "Trigger Click",
            systemImageName: "cursorarrow.click"
        )
    }
}
