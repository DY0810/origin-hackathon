import CoreLocation
import SwiftUI

/// The building / road / pole a report is about (CLAUDE.md §7.2). From supabase/functions/asset-lookup, or typed by the reporter.
struct Asset: Codable, Hashable, Identifiable {
    var kind: String            // building | road | sidewalk | bridge | pole | streetlight | structure | other
    var name: String
    var osmId: String? = nil
    var distanceM: Double? = nil

    var id: String { osmId ?? "\(kind):\(name)" }

    var symbol: String {
        switch kind {
        case "building": "building.2"
        case "road", "bridge": "road.lanes"
        case "sidewalk": "figure.walk"
        case "pole": "bolt"
        case "streetlight": "lightbulb"
        case "structure": "cube"
        default: "mappin.and.ellipse"
        }
    }
}

/// Live asset match while the camera is open (MASTER.md §7.1 AssetHeader + MultiplierChip). Never blocks capture:
/// a slow or failed lookup just leaves the header asking the reporter to name the asset.
@MainActor @Observable
final class AssetLookup {
    struct Match: Decodable {
        let primary: Asset?
        let candidates: [Asset]
        let address: String?
        let multiplier: Double?
        let danger: Bool?       // inside an active danger zone (CLAUDE.md §6.8)
        let reason: String?     // low_accuracy | lookup_failed
    }

    enum Status: Equatable { case waiting, found, failed }
    enum Choice: Equatable { case auto, picked(Asset), notSure }

    private(set) var status: Status = .waiting
    private(set) var match: Match?
    private(set) var multiplier: Double = 1
    private(set) var inDanger = false
    /// The reporter's pick sticks over later lookups.
    var choice: Choice = .auto

    private var anchor: (location: CLLocation, heading: Double?)?
    private var inFlight = false
    private var retryAt = Date.distantPast  // failed or empty lookups wait 5 s before asking Overpass again
    private var announced: String?

    nonisolated static let requeryMeters: CLLocationDistance = 15
    nonisolated static let requeryDegrees = 30.0
    static let maxAccuracy: CLLocationAccuracy = 30  // asset-lookup rejects worse fixes anyway

    var isPicked: Bool { if case .picked = choice { true } else { false } }

    /// What goes on the report: the pick, else the match. Nil = "Not sure" or nothing found.
    var asset: Asset? {
        switch choice {
        case .auto: match?.primary
        case .picked(let asset): asset
        case .notSure: nil
        }
    }

    /// Call on every location / heading change; only asks the server after a real move or turn.
    func update(location: CLLocation?, heading: Double?) {
        guard let location, location.horizontalAccuracy >= 0, location.horizontalAccuracy <= Self.maxAccuracy, !inFlight, Date.now >= retryAt,
              Self.shouldRequery(from: anchor, to: location, heading: heading) else { return }
        anchor = (location, heading)
        inFlight = true
        Task {
            await fetch(location, heading: heading)
            inFlight = false
        }
    }

    /// Moved more than 15 m, or turned more than 30° (or the compass just came up).
    nonisolated static func shouldRequery(from anchor: (location: CLLocation, heading: Double?)?, to location: CLLocation, heading: Double?) -> Bool {
        guard let anchor else { return true }
        if location.distance(from: anchor.location) > requeryMeters { return true }
        guard let heading else { return false }
        guard let old = anchor.heading else { return true }
        let turn = abs(heading - old).truncatingRemainder(dividingBy: 360)
        return min(turn, 360 - turn) > requeryDegrees
    }

    private func fetch(_ location: CLLocation, heading: Double?) async {
        let (lat, lng) = (location.coordinate.latitude, location.coordinate.longitude)
        let overpass = await Self.overpass(Self.overpassQuery(lat: lat, lng: lng))
        var body: [String: Any] = [
            "lat": lat, "lng": lng, "accuracy": Int(location.horizontalAccuracy.rounded()),
            "elements": overpass.flatMap(Self.overpassElements) ?? NSNull(),  // null: server answers lookup_failed + multiplier
        ]
        if let heading { body["heading"] = Int(heading.rounded()) }
        do {
            var request = Backend.request("asset-lookup", timeout: 12)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await Backend.data(for: request)
            guard response?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let result = try Backend.decoder.decode(Match.self, from: data)
            multiplier = result.multiplier ?? 1
            inDanger = result.danger ?? false
            guard result.reason != "lookup_failed" else { return failed() }
            match = result
            status = .found
            if result.primary == nil { anchor = nil; retryAt = .now.addingTimeInterval(5) }  // nothing mapped here yet: look again on the next fix
            announce()
        } catch {
            failed()
        }
    }

    // The phone queries OSM Overpass itself and asset-lookup only matches: from the Supabase edge runtime overpass-api.de
    // answers 406 (the runtime appends its own tag to every outbound User-Agent). Public instances are individually flaky
    // (errors, 5-15 s stalls), so every lookup races two.
    nonisolated static let overpassURLs = [
        URL(string: "https://overpass-api.de/api/interpreter")!, URL(string: "https://overpass.private.coffee/api/interpreter")!,
    ]
    nonisolated static let userAgent =
        "FaultLine/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") (iOS; https://github.com/DY0810/origin-hackathon)"

    /// Footprints (ways + multipolygons), road/path segments, bridges and point assets within 60 m, geometry inline and
    /// clipped to a 100 m half-size box (long roads would otherwise ship kilometres of points). `out geom`, not
    /// `out tags geom`, because relations need their members.
    nonisolated static func overpassQuery(lat: Double, lng: Double) -> String {
        let at = "(around:60,\(lat),\(lng))"
        let dLat = 100 / 111_320.0, dLng = dLat / cos(lat * .pi / 180)
        let bbox = [lat - dLat, lng - dLng, lat + dLat, lng + dLng].map { String(format: "%.6f", $0) }.joined(separator: ",")
        return "[out:json][timeout:8];(way\(at)[building];rel\(at)[building];way\(at)[highway];way\(at)[man_made=bridge];"
            + "node\(at)[power=pole];node\(at)[highway=street_lamp];node\(at)[man_made][man_made!=surveillance];);out geom(\(bbox));"
    }

    /// The `elements` array of an Overpass JSON answer; nil for an HTML error page or a JSON error without elements.
    nonisolated static func overpassElements(_ data: Data) -> [Any]? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["elements"] as? [Any]
    }

    /// First instance to answer with valid elements wins; the other is cancelled. Nil when both fail.
    nonisolated static func overpass(_ query: String) async -> Data? {
        let body = Data(("data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")).utf8)
        return await withTaskGroup(of: Data?.self) { group in
            for url in overpassURLs {
                group.addTask {
                    var request = URLRequest(url: url, timeoutInterval: 8)
                    request.httpMethod = "POST"
                    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                    request.httpBody = body
                    guard let (data, response) = try? await Backend.data(for: request), response?.statusCode == 200,
                          overpassElements(data) != nil else { return nil }
                    return data
                }
            }
            for await data in group where data != nil {
                group.cancelAll()
                return data
            }
            return nil
        }
    }

    /// Keep the last good match, and retry on a location/heading tick after 5 s (one request at a time).
    private func failed() {
        if match == nil { status = .failed }
        anchor = nil
        retryAt = .now.addingTimeInterval(5)
    }

    /// Only when the matched name changes, not on every re-query.
    private func announce() {
        guard choice == .auto else { return }
        let name = asset?.name ?? "New asset"
        guard name != announced else { return }
        announced = name
        var text = asset == nil ? name : "Asset: \(name)"
        if multiplier > 1 { text += ". \(multiplier.formatted()) times points zone" }
        AccessibilityNotification.Announcement(text).post()
    }
}

/// MASTER.md §6 AssetHeader: symbol + name + address + "Change". Camera overlay (glass, on media) or review form (card).
struct AssetHeader: View {
    let lookup: AssetLookup
    var onMedia = false
    let onChange: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .headline) private var iconWidth = FLSpace.xl  // grows with the spinner/pin glyph

    var body: some View {
        Button(action: onChange) {
            HStack(spacing: FLSpace.md) {
                Group {
                    if showsProgress { ProgressView().tint(primary) } else { Image(systemName: symbol) }
                }
                .font(.flHeadline)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: FLSpace.xs) {
                    Text(title).font(.flHeadline).lineLimit(lines)
                    if let subtitle { Text(subtitle).font(.flCaption).foregroundStyle(secondary).lineLimit(lines) }
                    if typeSize.isAccessibilitySize { change }  // beside the name it squeezes both to "Ass… Chang e"
                }
                Spacer(minLength: 0)
                if !typeSize.isAccessibilitySize { change }
            }
            .foregroundStyle(primary)
            .padding(.horizontal, FLSpace.md)
            .padding(.vertical, FLSpace.sm)
            .frame(minHeight: FLSpace.minTap)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Asset: \(title)\(subtitle.map { ", \($0)" } ?? ""). Change")
    }

    private var change: some View {
        Text("Change").font(.flCallout.weight(.semibold)).foregroundStyle(onMedia ? Color.flOnMedia : Color.flBrand)
    }

    private var primary: Color { onMedia ? .flOnMedia : .flInk }
    private var secondary: Color { onMedia ? .flOnMedia : .flInk2 }  // on media the caption size carries the hierarchy
    private var lines: Int? { typeSize.isAccessibilitySize ? nil : 1 }  // a line cap at AX sizes cuts words ("the ass…")
    private var showsProgress: Bool { lookup.choice == .auto && lookup.status == .waiting }

    private var symbol: String {
        if let asset = lookup.asset { return asset.symbol }
        return lookup.choice == .auto && lookup.status == .failed ? "questionmark.circle" : "mappin.and.ellipse"
    }

    private var title: String {
        if let asset = lookup.asset { return asset.name }
        switch (lookup.choice, lookup.status) {
        case (.notSure, _): return "Asset not set"
        case (_, .waiting): return "Finding the asset…"
        case (_, .failed): return "Asset unknown"
        default: return "New asset"
        }
    }

    private var subtitle: String? {
        if lookup.asset != nil { return lookup.choice == .auto ? lookup.match?.address : nil }
        return lookup.status == .waiting && lookup.choice == .auto ? nil : "Tap to name it"
    }
}

/// "Change" sheet: nearby candidates, a free-text name, or "Not sure".
struct AssetPicker: View {
    @Bindable var lookup: AssetLookup
    @Environment(\.dismiss) private var dismiss
    @State private var custom = ""

    var body: some View {
        NavigationStack {
            List {
                if let candidates = lookup.match?.candidates, !candidates.isEmpty {
                    Section {
                        ForEach(candidates) { asset in
                            Button { pick(.picked(asset)) } label: { row(asset) }
                        }
                    } header: { FLSectionHeader(title: "Nearby").textCase(nil).listRowInsets(EdgeInsets()) }
                    .listRowBackground(Color.flSurface2)
                }
                Section {
                    FLAdaptiveRow {
                        TextField("Name it, e.g. Main St Bridge", text: $custom)
                            .font(.flBody)
                            .submitLabel(.done)
                            .onSubmit(useCustom)
                        Button("Use", action: useCustom)
                            .disabled(trimmed.isEmpty)
                    }
                } header: { FLSectionHeader(title: "Something else").textCase(nil).listRowInsets(EdgeInsets()) }
                .listRowBackground(Color.flSurface2)
                Section {
                    Button("Not sure") { pick(.notSure) }
                }
                .listRowBackground(Color.flSurface2)
            }
            .scrollContentBackground(.hidden)  // white sheet, sky-tint rows (no grey)
            .font(.flBody)
            .navigationTitle("Which asset?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.flCanvas)
    }

    private var trimmed: String { custom.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func useCustom() {
        guard !trimmed.isEmpty else { return }
        pick(.picked(Asset(kind: "other", name: String(trimmed.prefix(120)))))
    }

    private func pick(_ choice: AssetLookup.Choice) {
        lookup.choice = choice
        dismiss()
    }

    private func row(_ asset: Asset) -> some View {
        HStack(spacing: FLSpace.md) {
            Image(systemName: asset.symbol).foregroundStyle(.flBrand).frame(width: FLSpace.xl).accessibilityHidden(true)
            Text(asset.name).font(.flBody).foregroundStyle(.flInk)
            Spacer(minLength: 0)
            if let meters = asset.distanceM {
                Text("\(Int(meters)) m").font(.flCaption.monospacedDigit()).foregroundStyle(.flInk2)
            }
            if asset == lookup.asset {
                Image(systemName: "checkmark").foregroundStyle(.flBrand).accessibilityLabel("Selected")
            }
        }
        .contentShape(.rect)
    }
}
