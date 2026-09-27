import SwiftUI
import UserNotifications

/// Profile > Settings: notifications, photo scan, reports waiting to send, onboarding, demo reset, about and licenses.
// ponytail: no units setting; distances are the system's locale default. Add one if a buyer market needs it.
struct SettingsScreen: View {
    let onReset: () async -> Void
    var onReportsChanged: () -> Void = {}

    @State private var notifications: UNAuthorizationStatus?
    @State private var isScanning = false
    @State private var isSending = false
    @State private var confirmReset = false
    @State private var isResetting = false
    @AppStorage("onboarded") private var onboarded = false
    @Environment(\.scenePhase) private var scenePhase
    private var outbox: OutboxStore { .shared }

    var body: some View {
        List {
            Section {
                LabeledContent("Notifications", value: notificationsText)
                if notifications == .notDetermined {
                    Button("Turn on notifications") { Task { await FixNotifier.requestPermission(); await readNotifications() } }
                } else {
                    Button("Open iPhone Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            } footer: {
                Text("Used only to tell you when a report is verified, sent or fixed.")
            }

            Section {
                Button("Scan my photos") { isScanning = true }
                LabeledContent("Waiting to send", value: outbox.count == 1 ? "1 report" : "\(outbox.count) reports")
                if outbox.count > 0 {
                    Button(isSending ? "Sending…" : "Send now") {
                        Task {
                            isSending = true
                            if await !outbox.flush().isEmpty { onReportsChanged() }
                            isSending = false
                        }
                    }
                    .disabled(isSending)
                }
            } header: {
                Text("Reports")
            } footer: {
                Text("Reports saved offline send on their own when you're back online.")
            }

            Section {
                Button("Show onboarding again") { onboarded = false }
                Button("Reset demo player", role: .destructive) { confirmReset = true }.disabled(isResetting)
            } header: {
                Text("Demo")
            }

            Section {
                LabeledContent("Version", value: version)
                Text("Photo scans run on your iPhone, and nothing uploads unless you approve it. Faces in scanned photos are blurred on your iPhone before upload.")
                Text("Map data © OpenStreetMap contributors. Dashboard map tiles by OpenFreeMap. Place names from Apple Maps.")
                Text("Road damage detector: YOLOv8n trained on RDD2022 (dronefreak/rdd2022-yolov8n), licensed AGPL-3.0.")
                Text("Damage classifier: EfficientNet-B0, fine-tuned by the FaultLine team.")
                Text("On-device speech: Whisper tiny.en via WhisperKit.")
            } header: {
                Text("About")
            }
            .font(.flCallout)
            .foregroundStyle(.flInk2)
        }
        .scrollContentBackground(.hidden)
        .background(.flCanvas)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: scenePhase) { await readNotifications() }  // re-read after a trip to iPhone Settings
        .fullScreenCover(isPresented: $isScanning, onDismiss: onReportsChanged) { GalleryScanScreen() }
        .confirmationDialog("Reset demo player?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset player", role: .destructive) {
                Task { isResetting = true; await onReset(); isResetting = false }
            }
        } message: {
            Text("You'll start over as a new player with 0 points. Reports you already sent stay on the map. Reports still waiting to send will go out as the new player.")
        }
    }

    private var notificationsText: String {
        switch notifications {
        case .authorized, .provisional, .ephemeral: "On"
        case .denied: "Off"
        case .notDetermined: "Not set"
        default: "…"
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    private func readNotifications() async {
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

#Preview { NavigationStack { SettingsScreen(onReset: {}) } }
