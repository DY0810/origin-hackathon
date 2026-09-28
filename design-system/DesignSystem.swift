// Mend design system: tokens + core atoms.
// Source of truth for rules: design-system/MASTER.md. Hex values must match contrast_check.py.
// Drop this file into the app target as-is. Screens use these tokens only, with no raw hex / point sizes.

import SwiftUI
import CoreText

// MARK: - Color tokens (light / dark pairs, all verified by contrast_check.py)

extension Color {
    init(light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
        #else
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(rgb: dark) : NSColor(rgb: light) })
        #endif
    }
}

#if canImport(UIKit)
import UIKit
private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#else
import AppKit
private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#endif

extension ShapeStyle where Self == Color {
    // Surfaces: "Cloud" (MASTER §2). Light is plain white (no grey backgrounds); dark is deep navy.
    static var flCanvas: Color { Color(light: 0xFFFFFF, dark: 0x0F141C) }   // screen background: white, never grey
    static var flSurface: Color { Color(light: 0xFEFEFE, dark: 0x18212D) }  // cards, sheets
    static var flSurface2: Color { Color(light: 0xF0F7FD, dark: 0x222D3B) }  // Sky tint: insets, chips, icon buttons, fields
    // Text
    static var flInk: Color { Color(light: 0x18212D, dark: 0xF4F6FA) }       // primary text ("Midnight")
    static var flInk2: Color { Color(light: 0x4E6A86, dark: 0xA9BACD) }      // secondary text (deep slate)
    static var flInk3: Color { Color(light: 0x6887A4, dark: 0x8A9FB6) }      // tertiary ("Slate"): large or non-essential only
    static var flStroke: Color { Color(light: 0x6887A4, dark: 0x6887A4) }    // control boundaries (3:1)
    // Brand: Midnight fill for the one primary action; flips to Sky in dark mode.
    static var flBrand: Color { Color(light: 0x18212D, dark: 0xADD9F3) }
    static var flOnBrand: Color { Color(light: 0xFEFEFE, dark: 0x18212D) }
    // Sky: soft accent. Selected chips, hero cards, secondary buttons. Never text on its own.
    static var flAccent: Color { Color(light: 0xADD9F3, dark: 0x2B4A66) }
    static var flOnAccent: Color { Color(light: 0x18212D, dark: 0xF4F6FA) }
    static var flAccentText: Color { Color(light: 0x2F6690, dark: 0xADD9F3) } // sky-blue as text: links, "View all"
    // Gold (Sunbeam) = points / value / bounty heat. Never used for anything else.
    static var flGold: Color { Color(light: 0xFFE66D, dark: 0xFFE66D) }
    static var flOnGold: Color { Color(light: 0x18212D, dark: 0x18212D) }
    static var flGoldText: Color { Color(light: 0x7A5E00, dark: 0xFFE66D) }
    // Feedback
    static var flSuccess: Color { Color(light: 0x1B7F4B, dark: 0x4CC38A) }
    static var flWarning: Color { Color(light: 0xA15C00, dark: 0xF5B040) }
    static var flDanger: Color { Color(light: 0xC8202F, dark: 0xFF6B6B) }
    static var flOnSeverity: Color { Color(light: 0xFFFFFF, dark: 0x0F141C) }
    // Camera / full-bleed photos: same in both themes. flOnMedia always sits on glass, a scrim, or flMedia.
    static var flMedia: Color { Color(light: 0x000000, dark: 0x000000) }
    static var flOnMedia: Color { Color(light: 0xFFFFFF, dark: 0xFFFFFF) }
}

// MARK: - Type: Poppins, every style tied to a Dynamic Type style so it scales to AX5.
// Poppins TTFs live in design-system/fonts (OFL). If they're missing, Font.custom falls back to SF Pro, so the app
// still builds and runs; FLFont.register() must run once at launch (MendApp.init).

enum FLFont {
    @MainActor static func register() {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "fonts") ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        #if canImport(UIKit)
        // Navigation bar titles are UIKit, so SwiftUI fonts don't reach them. Scaled so they still follow Dynamic Type.
        func scaled(_ name: String, _ size: CGFloat, _ style: UIFont.TextStyle) -> UIFont? {
            UIFont(name: name, size: size).map { UIFontMetrics(forTextStyle: style).scaledFont(for: $0) }
        }
        if let large = scaled("Poppins-Bold", 34, .largeTitle), let inline = scaled("Poppins-SemiBold", 17, .headline) {
            UINavigationBar.appearance().largeTitleTextAttributes = [.font: large]
            UINavigationBar.appearance().titleTextAttributes = [.font: inline]
        }
        if let button = scaled("Poppins-Medium", 17, .body) {  // toolbar "Cancel" / "Done" are UIKit bar buttons too
            for state: UIControl.State in [.normal, .highlighted, .disabled] {
                UIBarButtonItem.appearance().setTitleTextAttributes([.font: button], for: state)
            }
        }
        #endif
    }
}

extension Font {
    private static func poppins(_ weight: String, _ size: CGFloat, _ style: Font.TextStyle) -> Font {
        .custom("Poppins-\(weight)", size: size, relativeTo: style)
    }
    static let flDisplay = poppins("Bold", 34, .largeTitle)        // point totals, level-up, hero numbers
    static let flTitle = poppins("SemiBold", 26, .title)            // screen / sheet titles ("Join Us")
    static let flSection = poppins("SemiBold", 19, .title3)         // section headers ("Today's focus")
    static let flHeadline = poppins("SemiBold", 16, .headline)      // card titles, buttons, chips
    static let flBody = poppins("Regular", 16, .body)
    static let flCallout = poppins("Regular", 14, .callout)         // subtitles, supporting copy
    static let flCaption = poppins("Medium", 12, .caption)          // metadata, badges; smallest allowed
    static let flNumber = poppins("SemiBold", 20, .title3).monospacedDigit() // points, XP, counts
}

// MARK: - Spacing, radius, motion

enum FLSpace {
    static let xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16
    static let xl: CGFloat = 24, xxl: CGFloat = 32, xxxl: CGFloat = 48
    static let gutter: CGFloat = 16      // screen horizontal inset
    static let minTap: CGFloat = 44      // minimum hit target
}

enum FLRadius {
    static let sm: CGFloat = 10, md: CGFloat = 16, lg: CGFloat = 24, xl: CGFloat = 32
}

enum FLSize {
    static let button: CGFloat = 56      // primary / secondary button min height
    static let iconButton: CGFloat = 44  // square icon buttons (back, close, bell)
}

enum FLMotion {
    static let quick = Animation.snappy(duration: 0.2)     // press, toggle, chip select
    static let standard = Animation.smooth(duration: 0.3)  // sheet content, list changes
    static let reward = Animation.bouncy(duration: 0.45)   // ONLY points earned / level-up / badge unlocked
    /// Returns nil when Reduce Motion is on, so `withAnimation(FLMotion.resolve(.reward, reduceMotion))` just snaps.
    static func resolve(_ animation: Animation, _ reduceMotion: Bool) -> Animation? { reduceMotion ? nil : animation }
}

// MARK: - Severity (1–5). Always shown as color + icon + numeral, never color alone.

enum Severity: Int, CaseIterable, Identifiable, Codable, Comparable {
    case cosmetic = 1, monitor, schedule, urgent, hazard

    var id: Int { rawValue }
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .cosmetic: "Cosmetic"
        case .monitor: "Monitor"
        case .schedule: "Repair soon"
        case .urgent: "Urgent"
        case .hazard: "Hazard"
        }
    }

    var symbol: String {
        switch self {
        case .cosmetic: "info.circle.fill"
        case .monitor: "eye.fill"
        case .schedule: "wrench.and.screwdriver.fill"
        case .urgent: "exclamationmark.triangle.fill"
        case .hazard: "exclamationmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .cosmetic: Color(light: 0x5B6878, dark: 0x9AA6B6)
        case .monitor: Color(light: 0x1F72C4, dark: 0x5AA9F0)
        case .schedule: Color(light: 0x9E6300, dark: 0xF0A62A)
        case .urgent: Color(light: 0xC9480A, dark: 0xFF8540)
        case .hazard: Color(light: 0xC8202F, dark: 0xFF5A64)
        }
    }

    var accessibilityText: String { "Severity \(rawValue) of 5, \(label)" }
}

// MARK: - Atoms

/// The single primary action on a screen: Midnight capsule, bottom of the screen.
struct FLPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.flHeadline)
            .multilineTextAlignment(.center)
            .foregroundStyle(.flOnBrand)
            .padding(.vertical, FLSpace.sm)  // keeps a wrapped label off the capsule edge; 56 pt min still rules at default size
            .frame(maxWidth: .infinity, minHeight: FLSize.button)
            .padding(.horizontal, FLSpace.xl)
            .background(.flBrand, in: .capsule)
            .shadow(color: .flBrand.opacity(isEnabled ? 0.18 : 0), radius: 12, y: 6)
            .opacity(isEnabled ? (configuration.isPressed && reduceMotion ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(FLMotion.quick, value: configuration.isPressed)
    }
}

/// Supporting actions: soft Sky capsule. Never two primaries on one screen.
struct FLSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.flHeadline)
            .multilineTextAlignment(.center)
            .foregroundStyle(.flOnAccent)
            .padding(.vertical, FLSpace.sm)
            .frame(maxWidth: .infinity, minHeight: FLSize.button)
            .padding(.horizontal, FLSpace.xl)
            .background(.flAccent.gradient, in: .capsule)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

extension ButtonStyle where Self == FLPrimaryButtonStyle { static var flPrimary: Self { .init() } }
extension ButtonStyle where Self == FLSecondaryButtonStyle { static var flSecondary: Self { .init() } }

struct SeverityBadge: View {
    let severity: Severity
    var showsLabel = true

    var body: some View {
        HStack(spacing: FLSpace.xs) {
            Image(systemName: severity.symbol)
            Text("\(severity.rawValue)").monospacedDigit()
            if showsLabel { Text(severity.label) }
        }
        .font(.flCaption.weight(.bold))
        .foregroundStyle(.flOnSeverity)
        .padding(.horizontal, FLSpace.sm)
        .padding(.vertical, FLSpace.xs)
        .background(severity.color, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(severity.accessibilityText)
    }
}

/// Points. `pending` = awarded but not yet settled by fraud checks.
/// Drops the star, then stacks "pending" under the number, before any word would break (AX sizes, narrow cards).
struct PointsPill: View {
    let points: Int
    var pending = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: FLSpace.xs) { star; number; pendingText }
            HStack(spacing: FLSpace.xs) { number; pendingText }
            VStack(alignment: .leading, spacing: 0) { number; pendingText }
        }
        .font(.flHeadline.monospacedDigit())
        .foregroundStyle(.flOnGold)
        .padding(.horizontal, FLSpace.md)
        .padding(.vertical, FLSpace.xs)
        // Radius clamps to a capsule on one line and stays a rounded rect when stacked.
        .background(.flGold.opacity(pending ? pendingOpacity : 1), in: .rect(cornerRadius: FLRadius.lg))
        .overlay { if pending { RoundedRectangle(cornerRadius: FLRadius.lg).strokeBorder(.flOnGold, style: .init(lineWidth: 1, dash: [3, 3])) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(points) points\(pending ? ", pending review" : "")")
    }

    /// 45% gold on navy is 3.7:1 for the navy label; 75% keeps it above 4.5:1. The dashed border marks pending either way.
    private var pendingOpacity: Double { colorScheme == .dark ? 0.75 : 0.45 }
    private var star: some View { Image(systemName: "star.circle.fill") }
    private var number: some View { Text("\(points)").contentTransition(.numericText(value: Double(points))) }
    @ViewBuilder private var pendingText: some View { if pending { Text("pending").fontWeight(.regular) } }
}

/// Zone multiplier shown on map hexes, quest cards, and the capture screen.
struct MultiplierChip: View {
    let multiplier: Double

    var body: some View {
        Text(multiplier.formatted(.number.precision(.fractionLength(0...2))) + "×")  // surge moves in 0.25 steps
            .font(.flCaption.weight(.heavy).monospacedDigit())
            .foregroundStyle(.flOnGold)
            .padding(.horizontal, FLSpace.sm)
            .padding(.vertical, 2)
            .background(.flGold, in: .capsule)
            .accessibilityLabel("\(multiplier.formatted()) times points zone")
    }
}

enum ReportStatus {
    case pending, accepted, review, rejected, failed, dangerZone, fixed, queued

    var text: String {
        switch self {
        case .pending: "Checking your report…"
        case .accepted: "Verified. Nice find."
        case .review: "A reviewer will confirm this one."
        case .rejected: "Not counted as damage."
        case .failed: "Couldn't send your report."
        case .dangerZone: "Unsafe area. Reports paused here."
        case .fixed: "Fixed. Thanks for reporting it."
        case .queued: "Saved. Sends when you're back online."
        }
    }

    var symbol: String {
        switch self {
        case .pending: "hourglass"
        case .accepted: "checkmark.seal.fill"
        case .review: "person.fill.questionmark"
        case .rejected: "xmark.circle.fill"
        case .failed: "wifi.exclamationmark"
        case .dangerZone: "flame.fill"
        case .fixed: "wrench.and.screwdriver.fill"
        case .queued: "tray.and.arrow.up.fill"
        }
    }

    var tint: Color {
        switch self {
        case .pending, .review, .queued: .flInk2
        case .accepted, .fixed: .flSuccess
        case .rejected, .failed: .flWarning
        case .dangerZone: .flDanger
        }
    }
}

struct StatusBanner: View {
    let status: ReportStatus
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: FLSpace.sm) {
            Image(systemName: status.symbol).foregroundStyle(status.tint)
            VStack(alignment: .leading, spacing: FLSpace.xs) {
                Text(status.text).font(.flHeadline).foregroundStyle(.flInk)
                if let detail { Text(detail).font(.flCallout).foregroundStyle(.flInk2) }
            }
            Spacer(minLength: 0)
        }
        .padding(FLSpace.md)
        .background(.flSurface2, in: .rect(cornerRadius: FLRadius.lg))
        .accessibilityElement(children: .combine)
    }
}

/// Container: white card, big radius, one soft shadow. Increase Contrast swaps the shadow for a stroke.
struct FLCardModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .padding(FLSpace.lg)
            .background(.flSurface, in: .rect(cornerRadius: FLRadius.lg))
            .overlay { if contrast == .increased { RoundedRectangle(cornerRadius: FLRadius.lg).strokeBorder(.flStroke) } }
            .shadow(color: .flInk.opacity(0.06), radius: 16, y: 6)
    }
}

/// The one highlighted card at the top of a screen (level, balance, today's quest): Sky gradient, extra-large radius.
struct FLHeroCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.flOnAccent)
            .padding(FLSpace.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [.flAccent, .flAccent.opacity(0.55)], startPoint: .top, endPoint: .bottom),
                        in: .rect(cornerRadius: FLRadius.xl))
    }
}

extension View {
    func flCard() -> some View { modifier(FLCardModifier()) }
    func flHeroCard() -> some View { modifier(FLHeroCardModifier()) }
}

/// Selectable pill (filters, choices). Text only; selected = Sky fill + 2 pt Midnight outline.
struct FLChip: View {
    let title: String
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
            .font(.flCaption)
            .foregroundStyle(isSelected ? .flOnAccent : .flInk)
            .padding(.horizontal, FLSpace.md)
            .frame(minHeight: FLSpace.minTap)
            .background(isSelected ? AnyShapeStyle(.flAccent) : AnyShapeStyle(.flSurface2), in: .capsule)
            .overlay { if isSelected { Capsule().strokeBorder(.flBrand, lineWidth: 2) } }  // a shape cue, not color alone
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .animation(FLMotion.quick, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Square icon button (back, close, notifications): rounded-square Surface2 tile, 44 pt.
struct FLIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.flHeadline)
                .foregroundStyle(.flInk)
                .frame(width: FLSize.iconButton, height: FLSize.iconButton)
                .background(.flSurface2, in: .rect(cornerRadius: FLRadius.sm))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// "Emergency level ........ [badge]": label left, value right. An optional note ("Preliminary") sits under the label so
/// the label stays short enough to keep the value on the right. Every row stacks at accessibility sizes, so a card's rows
/// never mix inline and stacked; below that it stacks only if the value can't fit.
struct FLInfoRow<Value: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder let value: () -> Value
    @Environment(\.dynamicTypeSize) private var typeSize

    private var label: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.flCallout).foregroundStyle(.flInk2)
            if let note { Text(note).font(.flCaption).foregroundStyle(.flInk2) }
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: FLSpace.xs) { label; value() }
    }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                stacked
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: FLSpace.sm) { label; Spacer(minLength: FLSpace.sm); value() }
                    stacked
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: FLSpace.minTap, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A row of title + pill/value that stacks (leading) at accessibility sizes, so a long title never loses width to the
/// pill and splits mid-word (MASTER §5). Put a `Spacer(minLength: 0)` between the parts; it collapses when stacked.
struct FLAdaptiveRow<Content: View>: View {
    var alignment: VerticalAlignment = .center
    var spacing: CGFloat = FLSpace.sm
    @ViewBuilder let content: () -> Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
                                                  : AnyLayout(HStackLayout(alignment: alignment, spacing: spacing))
        layout(content)
    }
}

/// MASTER §6 EmptyState: symbol, one line, optional action. ContentUnavailableView draws SF Pro unless we set the fonts.
struct FLEmptyState<Actions: View>: View {
    let title: String
    let systemImage: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage).font(.flTitle).foregroundStyle(.flInk)
        } description: {
            Text(message).font(.flBody).foregroundStyle(.flInk2)
        } actions: {
            actions()
        }
    }
}

extension FLEmptyState where Actions == EmptyView {
    init(title: String, systemImage: String, message: String) {
        self.init(title: title, systemImage: systemImage, message: message) { EmptyView() }
    }
}

/// "Today's focus ........ View all →"
struct FLSectionHeader: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.flSection).foregroundStyle(.flInk).accessibilityAddTraits(.isHeader)
            Spacer(minLength: FLSpace.sm)
            if let actionTitle, let action {
                Button(action: action) { Label(actionTitle, systemImage: "arrow.right").labelStyle(TrailingIconLabelStyle()) }
                    .font(.flCaption)
                    .foregroundStyle(.flAccentText)
                    .frame(minHeight: FLSpace.minTap)
            }
        }
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: FLSpace.xs) { configuration.title; configuration.icon }
    }
}

/// Small white stat tile, usually inside a hero card ("Hunger 65%" in the refs → "Streak 4 days").
struct FLStatTile: View {
    let title: String
    let systemImage: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: FLSpace.xs) {
            Label(title, systemImage: systemImage).font(.flCaption).foregroundStyle(.flInk2)
            Text(value).font(.flNumber).foregroundStyle(.flInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FLSpace.md)
        .background(.flSurface, in: .rect(cornerRadius: FLRadius.md))
        .accessibilityElement(children: .combine)
    }
}

#Preview("Atoms") {
    ScrollView {
        VStack(alignment: .leading, spacing: FLSpace.lg) {
            HStack { FLIconButton(systemImage: "chevron.left", label: "Back") {}; Spacer(); FLIconButton(systemImage: "bell", label: "Notifications") {} }
            Text("Good afternoon").font(.flTitle).foregroundStyle(.flInk)
            VStack(alignment: .leading, spacing: FLSpace.md) {
                Text("Level 4 · Inspector").font(.flHeadline)
                Text("1,240").font(.flDisplay)
                HStack { FLStatTile(title: "Streak", systemImage: "flame", value: "4 days"); FLStatTile(title: "Finds", systemImage: "scope", value: "18") }
            }
            .flHeroCard()
            FLSectionHeader(title: "Nearby bounties", actionTitle: "View all") {}
            HStack { FLChip(title: "Crack", isSelected: true) {}; FLChip(title: "Pothole") {} }
            HStack { PointsPill(points: 120); PointsPill(points: 45, pending: true); MultiplierChip(multiplier: 2) }
            VStack(alignment: .leading) { ForEach(Severity.allCases) { SeverityBadge(severity: $0) } }
            StatusBanner(status: .accepted, detail: "Spalling on 123 Oak Ave, north wall")
            StatusBanner(status: .dangerZone)
            Text("Card content").font(.flBody).frame(maxWidth: .infinity, alignment: .leading).flCard()
            Button("Submit report") {}.buttonStyle(.flPrimary)
            Button("Retake") {}.buttonStyle(.flSecondary)
            Button("Disabled") {}.buttonStyle(.flPrimary).disabled(true)
        }
        .padding(FLSpace.gutter)
    }
    .background(.flCanvas)
}
