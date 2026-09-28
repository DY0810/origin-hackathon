import AVFoundation
import CoreLocation
import SwiftUI
import UserNotifications

/// First launch only (RootView, `@AppStorage("onboarded")`). What Mend is, how points and safety work, then each
/// permission explained on its own page and requested only when the player taps its button (MASTER.md §1.7: no dark
/// patterns; "Not now" always works and Skip is always there). Pages crossfade: no slides or parallax.
struct OnboardingScreen: View {
    let onFinish: () -> Void

    enum Page: Int, CaseIterable {
        case welcome, safety, location, camera, notifications

        var symbol: String {
            switch self {
            case .welcome: "camera.viewfinder"
            case .safety: "figure.walk"
            case .location: "location.fill"
            case .camera: "camera.fill"
            case .notifications: "bell.fill"
            }
        }

        var title: String {
            switch self {
            case .welcome: "Spot it. Snap it. Earn."
            case .safety: "Stay safe, always"
            case .location: "Your location"
            case .camera: "Your camera"
            case .notifications: "Updates on your reports"
            }
        }

        var body: String {
            switch self {
            case .welcome: "See a crack, a pothole or a leaning pole? Photograph it. Mend checks the photo, rates how serious it is, and sends it to the people who fix it. You earn points you can trade for gift cards."
            case .safety: "Only take photos from public sidewalks and streets. Never go past a barrier or into a fire, flood or evacuation area: reports there earn nothing. Points show as pending until your report passes checks, usually within a day."
            case .location: "Mend needs your location to work out which building, road or pole you're photographing, to warn you about unsafe areas and to show bounty zones near you. It's used only while the app is open."
            case .camera: "Reports come from the in-app camera, so we know the photo is new and where it was taken. Photos upload only when you tap Submit."
            case .notifications: "We can tell you when a report is verified, when one saved offline gets sent, and when something you reported gets fixed. Nothing else."
            }
        }

        /// Permission button label; nil for the info pages.
        var ask: String? {
            switch self {
            case .welcome, .safety: nil
            case .location: "Allow location"
            case .camera: "Allow camera"
            case .notifications: "Allow notifications"
            }
        }
    }

    enum Access { case notAsked, granted, denied }

    @State private var page = Page.welcome
    @State private var isAsking = false
    @State private var notifications: UNAuthorizationStatus = .notDetermined
    @State private var location = LocationPermission()
    @AccessibilityFocusState private var focusedTitle: Page?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Step \(page.rawValue + 1) of \(Page.allCases.count)").font(.flCaption).foregroundStyle(.flInk2)
                Spacer()
                Button("Skip", action: onFinish).font(.flHeadline).frame(minHeight: FLSpace.minTap)
                    .accessibilityHint("Goes to the map. You can see this again in Profile, Settings.")
            }
            .padding(.horizontal, FLSpace.gutter)

            ScrollView {
                VStack(spacing: FLSpace.xl) {
                    Image(systemName: page.symbol)
                        .font(.flDisplay)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.flBrand)
                        .accessibilityHidden(true)
                    VStack(spacing: FLSpace.sm) {
                        Text(page.title).font(.flTitle).foregroundStyle(.flInk)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($focusedTitle, equals: page)
                        Text(page.body).font(.flCallout).foregroundStyle(.flInk2)
                        if let note = accessNote { Text(note).font(.flCallout.weight(.semibold)).foregroundStyle(.flInk) }
                    }
                    .multilineTextAlignment(.center)
                }
                .padding(FLSpace.gutter)
                .padding(.top, FLSpace.xxxl)
                .id(page)
                .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .bottom) {  // pinned, so long copy at large text sizes scrolls instead of truncating
            VStack(spacing: FLSpace.sm) { buttons }
                .padding(FLSpace.gutter)
                .background(.flCanvas)
        }
        .background(.flCanvas)
        // Focus the new title once the crossfade has put it on screen; setting it in the same tick as the page change
        // targets a view that doesn't exist yet.
        .task(id: page) {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 50 : 350))
            focusedTitle = page
        }
        // Re-read after a trip to iPhone Settings.
        .task(id: scenePhase) {
            notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    }

    @ViewBuilder private var buttons: some View {
        switch access(page) {
        case .notAsked?:
            Button { Task { await request() } } label: {
                if isAsking { ProgressView().tint(.flOnBrand) } else { Text(page.ask ?? "") }
            }
            .buttonStyle(.flPrimary)
            .disabled(isAsking)
            Button("Not now", action: next).buttonStyle(.flSecondary).disabled(isAsking)
        case .denied?:
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.flPrimary)
            Button("Not now", action: next).buttonStyle(.flSecondary)
        case .granted?, nil:
            Button("Next", action: next).buttonStyle(.flPrimary)
        }
    }

    private var accessNote: String? {
        switch access(page) {
        case .granted?: "Already on."
        case .denied?: "Turned off. You can change it in Settings."
        default: nil
        }
    }

    /// Current state of the page's permission; nil for the info pages.
    private func access(_ page: Page) -> Access? {
        switch page {
        case .welcome, .safety: return nil
        case .location:
            return location.isAllowed ? .granted : location.status == .notDetermined ? .notAsked : .denied
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }
        case .notifications:
            switch notifications {
            case .authorized, .provisional, .ephemeral: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }
        }
    }

    private func next() {
        guard let following = Page(rawValue: page.rawValue + 1) else { return onFinish() }
        withAnimation(FLMotion.resolve(FLMotion.standard, reduceMotion)) { page = following }
    }

    /// Asks for this page's permission, waits for the answer, then moves on whatever it was.
    private func request() async {
        isAsking = true
        defer { isAsking = false }
        switch page {
        case .location: await location.request()
        case .camera: _ = await AVCaptureDevice.requestAccess(for: .video)
        case .notifications:
            await FixNotifier.requestPermission()
            notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        case .welcome, .safety: break
        }
        next()
    }
}

#Preview { OnboardingScreen(onFinish: {}) }
