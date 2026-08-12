import SwiftUI

@MainActor
enum PhoneComposition {
    private final class ModelBox { weak var model: PhoneAppModel? }
    private final class CoordinatorBox { weak var actions: PhoneActionCoordinator? }

    static func makeModel(defaults: UserDefaults = .standard,
                          secrets: any SecretStoring = KeychainStore()) -> PhoneAppModel {
        let settings = (try? PhoneSettingsStore(defaults: defaults, secrets: secrets))
            ?? PhoneSettingsStore.unavailable(defaults: defaults)
        let scheduler = MainQueuePhoneScheduler()
        let clock = SystemPhoneClock()
        let transport = PhoneRelayClient(socketFactory: URLSessionPhoneWebSocketFactory(),
                                         clock: clock,
                                         scheduler: scheduler)
        let modelBox = ModelBox()
        let actions = PhoneActionCoordinator(transport: transport,
                                             clock: clock,
                                             scheduler: scheduler,
                                             haptics: TerminalNotificationHaptics()) { phase in
            modelBox.model?.applyActionPhase(phase)
        }
        let coordinatorBox = CoordinatorBox()
        coordinatorBox.actions = actions
        let clockHealth = PhoneClockHealthController(clock: clock,
                                                     scheduler: scheduler,
                                                     isActionPending: { coordinatorBox.actions?.hasPendingAction ?? false }) { health in
            modelBox.model?.applyClockHealth(health)
        }
        let model = PhoneAppModel(settings: settings,
                                  volumeController: VolumeDeltaController(source: AVAudioSessionVolumeSource()),
                                  transport: transport,
                                  clockHealth: clockHealth,
                                  actions: actions)
        let pairing = PhonePairingClient(socketFactory: URLSessionPhoneWebSocketFactory(),
                                         settings: settings,
                                         normalTransport: transport,
                                         clock: clock,
                                         scheduler: scheduler)
        model.installPairingClient(pairing)
        modelBox.model = model
        return model
    }
}

@main
struct ClickBridgePhoneApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = PhoneComposition.makeModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onOpenURL(perform: model.handlePairingInvitation)
        }
            .onChange(of: scenePhase, initial: true) { _, phase in
                model.scenePhaseChanged(phase)
            }
    }
}
