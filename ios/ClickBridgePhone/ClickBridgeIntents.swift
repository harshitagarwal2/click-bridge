import AppIntents

struct TriggerClickIntent: AppIntent {
    static var title: LocalizedStringResource = "Trigger 3 Clicks"
    static var description = IntentDescription("Open Click Bridge and send three ordinary clicks to the connected Mac.")
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
                "Trigger three clicks with \(.applicationName)",
                "Click three times using \(.applicationName)",
            ],
            shortTitle: "Trigger 3 Clicks",
            systemImageName: "cursorarrow.click"
        )
    }
}
