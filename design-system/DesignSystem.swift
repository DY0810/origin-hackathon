// FaultLine design system: tokens + core atoms.
// Source of truth for rules: design-system/MASTER.md. Hex values must match contrast_check.py.
// Drop this file into the app target as-is. Screens use these tokens only, with no raw hex / point sizes.

import SwiftUI

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
    // Surfaces
    static var flCanvas: Color { Color(light: 0xF4F3EF, dark: 0x0B0D10) }   // screen background ("concrete")
    static var flSurface: Color { Color(light: 0xFFFFFF, dark: 0x171A1F) }  // cards, sheets
    static var flSurface2: Color { Color(light: 0xECEAE4, dark: 0x22262D) }  // insets, secondary buttons
    // Text
    static var flInk: Color { Color(light: 0x101318, dark: 0xF2F4F7) }       // primary text
    static var flInk2: Color { Color(light: 0x4A5361, dark: 0xA7B0BD) }      // secondary text
    static var flInk3: Color { Color(light: 0x6B7483, dark: 0x838C99) }      // tertiary: large or non-essential only
    static var flStroke: Color { Color(light: 0x8A93A1, dark: 0x5D6673) }    // control boundaries (3:1)
    // Brand: Survey Blue. The one interactive color.
    static var flBrand: Color { Color(light: 0x2350E6, dark: 0x6E8EFF) }
    static var flOnBrand: Color { Color(light: 0xFFFFFF, dark: 0x0B0D10) }
    // Gold = points / value / bounty heat. Never used for anything else.
    static var flGold: Color { Color(light: 0xFFC233, dark: 0xFFC940) }
    static var flOnGold: Color { Color(light: 0x101318, dark: 0x101318) }
    static var flGoldText: Color { Color(light: 0x8A5A00, dark: 0xFFD166) }
    // Feedback
    static var flSuccess: Color { Color(light: 0x1B7F4B, dark: 0x4CC38A) }
    static var flWarning: Color { Color(light: 0xA15C00, dark: 0xF5B040) }
    static var flDanger: Color { Color(light: 0xC8202F, dark: 0xFF6B6B) }
    static var flOnSeverity: Color { Color(light: 0xFFFFFF, dark: 0x0B0D10) }
    // Camera / full-bleed photos: same in both themes. flOnMedia always sits on glass, a scrim, or flMedia.
    static var flMedia: Color { Color(light: 0x000000, dark: 0x000000) }
    static var flOnMedia: Color { Color(light: 0xFFFFFF, dark: 0xFFFFFF) }
}

// MARK: - Type (Dynamic Type text styles only; never fixed point sizes)

extension Font {
    static let flDisplay = Font.system(.largeTitle, design: .rounded, weight: .heavy)  // point totals, level-up
    static let flTitle = Font.system(.title2, design: .rounded, weight: .bold)         // screen / sheet titles
    static let flHeadline = Font.headline                                             // card titles, buttons
    static let flBody = Font.body
    static let flCallout = Font.callout                                               // supporting copy
    static let flCaption = Font.caption                                               // metadata; smallest allowed
    static let flNumber = Font.system(.title3, design: .rounded, weight: .bold).monospacedDigit() // points, XP, counts
}

// MARK: - Spacing, radius, motion

enum FLSpace {
    static let xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16
    static let xl: CGFloat = 24, xxl: CGFloat = 32, xxxl: CGFloat = 48
    static let gutter: CGFloat = 16      // screen horizontal inset
    static let minTap: CGFloat = 44      // minimum hit target
}

enum FLRadius {
    static let sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 20
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

/// The single primary action on a screen.
struct FLPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.flHeadline)
            .foregroundStyle(.flOnBrand)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, FLSpace.lg)
            .background(.flBrand, in: .rect(cornerRadius: FLRadius.md))
            .opacity(isEnabled ? (configuration.isPressed && reduceMotion ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(FLMotion.quick, value: configuration.isPressed)
    }
}

/// Supporting actions. Never two primaries on one screen.
struct FLSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.flHeadline)
            .foregroundStyle(.flInk)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, FLSpace.lg)
            .background(.flSurface2, in: .rect(cornerRadius: FLRadius.md))
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
struct PointsPill: View {
    let points: Int
    var pending = false

    var body: some View {
        HStack(spacing: FLSpace.xs) {
            Image(systemName: "star.circle.fill")
            Text("\(points)").contentTransition(.numericText(value: Double(points)))
            if pending { Text("pending").fontWeight(.regular) }
        }
        .font(.flHeadline.monospacedDigit())
        .foregroundStyle(.flOnGold)
        .padding(.horizontal, FLSpace.md)
        .padding(.vertical, FLSpace.xs)
        .background(.flGold.opacity(pending ? 0.45 : 1), in: .capsule)
        .overlay { if pending { Capsule().strokeBorder(.flOnGold, style: .init(lineWidth: 1, dash: [3, 3])) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(points) points\(pending ? ", pending review" : "")")
    }
}

/// Zone multiplier shown on map hexes, quest cards, and the capture screen.
struct MultiplierChip: View {
    let multiplier: Double

    var body: some View {
        Text(multiplier.formatted(.number.precision(.fractionLength(0...1))) + "×")
            .font(.flCaption.weight(.heavy).monospacedDigit())
            .foregroundStyle(.flOnGold)
            .padding(.horizontal, FLSpace.sm)
            .padding(.vertical, 2)
            .background(.flGold, in: .capsule)
            .accessibilityLabel("\(multiplier.formatted()) times points zone")
    }
}

/// Privacy marker for anything processed without leaving the phone (gallery scan, Foundation Models drafts).
struct OnDeviceBadge: View {
    var body: some View {
        Label("On-device", systemImage: "lock.iphone")
            .font(.flCaption)
            .foregroundStyle(.flInk2)
            .accessibilityLabel("Processed on your iPhone. Nothing uploaded.")
    }
}

enum ReportStatus {
    case pending, accepted, review, rejected, failed, dangerZone

    var text: String {
        switch self {
        case .pending: "Checking your report…"
        case .accepted: "Verified. Nice find."
        case .review: "A reviewer will confirm this one."
        case .rejected: "Not counted as damage."
        case .failed: "Couldn't send your report."
        case .dangerZone: "Unsafe area. Reports paused here."
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
        }
    }

    var tint: Color {
        switch self {
        case .pending, .review: .flInk2
        case .accepted: .flSuccess
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
        .background(.flSurface2, in: .rect(cornerRadius: FLRadius.md))
        .accessibilityElement(children: .combine)
    }
}

struct FLCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(FLSpace.lg)
            .background(.flSurface, in: .rect(cornerRadius: FLRadius.lg))
            .overlay(RoundedRectangle(cornerRadius: FLRadius.lg).strokeBorder(.flInk.opacity(0.08)))
    }
}

extension View {
    func flCard() -> some View { modifier(FLCardModifier()) }
}

#Preview("Atoms") {
    ScrollView {
        VStack(alignment: .leading, spacing: FLSpace.lg) {
            Text("1,240").font(.flDisplay).foregroundStyle(.flInk)
            HStack { PointsPill(points: 120); PointsPill(points: 45, pending: true); MultiplierChip(multiplier: 2) }
            VStack(alignment: .leading) { ForEach(Severity.allCases) { SeverityBadge(severity: $0) } }
            StatusBanner(status: .accepted, detail: "Spalling on 123 Oak Ave, north wall")
            StatusBanner(status: .dangerZone)
            OnDeviceBadge()
            Button("Submit report") {}.buttonStyle(.flPrimary)
            Button("Retake") {}.buttonStyle(.flSecondary)
            Button("Disabled") {}.buttonStyle(.flPrimary).disabled(true)
        }
        .padding(FLSpace.gutter)
    }
    .background(.flCanvas)
}
