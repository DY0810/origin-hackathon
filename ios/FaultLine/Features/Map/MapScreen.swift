import MapKit
import SwiftUI

/// Map tab (design-system/MASTER.md §7.3): bounty heat (gold H3 hexes) + damage pins, layer toggle,
/// list alternative, capture button.
struct MapScreen: View {
    let onCapture: () -> Void
    /// Bumped by RootView after a capture closes, so a new report shows up.
    let refreshToken: Int

    // ponytail: USC fallback until the demo city is picked (CLAUDE.md §14).
    static let demoRegion = MKCoordinateRegion(center: .init(latitude: 34.0225, longitude: -118.2851),
                                               span: .init(latitudeDelta: 0.045, longitudeDelta: 0.045))

    @State private var locationManager = CLLocationManager()
    @State private var model = MapModel()
    @State private var layer: MapLayer = .both
    @State private var position: MapCameraPosition = .userLocation(fallback: .region(Self.demoRegion))
    @State private var region = Self.demoRegion
    @State private var selected: MapReport?
    @State private var selectedCell: HeatCell?
    @State private var selectedStop: CampaignStop?
    @State private var captureAfterSheet = false
    @State private var showList = false

    /// MASTER §7.3: inside a danger core the Capture button is disabled with an explanation.
    private var inDangerArea: Bool {
        guard let here = locationManager.location?.coordinate else { return false }
        return model.snapshot.cell(at: here)?.danger == true
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                UserAnnotation()
                if layer.showsHeat {
                    ForEach(model.snapshot.cells) { cell in
                        MapPolygon(coordinates: cell.coordinates)
                            .foregroundStyle(cell.danger ? Color.flDanger.opacity(0.3) : Color.flGold.opacity(HeatStyle.opacity(for: cell.multiplier)))
                            // ponytail: static dashed surge outline (MASTER §6 animates it); animating re-diffs every Map polygon, move to its own overlay if we want motion
                            .stroke(cell.danger || cell.surge ? Color.flDanger : Color.flGold.opacity(0.7),
                                    style: cell.danger ? StrokeStyle(lineWidth: 2)
                                         : cell.surge ? StrokeStyle(lineWidth: 2, dash: [4, 3]) : StrokeStyle(lineWidth: 0.5))
                    }
                    ForEach(model.snapshot.bounties) { bounty in
                        Annotation(bounty.name, coordinate: bounty.coordinate, anchor: .bottom) {
                            BountyLabel(bounty: bounty, showsName: layer == .bounties)  // names only when pins are hidden
                        }
                        .annotationTitles(.hidden)
                    }
                }
                if layer.showsPins {
                    ForEach(model.snapshot.reports) { report in
                        Annotation(report.typeLabel, coordinate: report.coordinate) {
                            DamagePin(report: report, isSelected: selected == report) { selected = report }
                        }
                        .annotationTitles(.hidden)
                    }
                }
                ForEach(model.snapshot.stops) { stop in
                    Annotation(stop.title, coordinate: stop.coordinate, anchor: .bottom) {
                        SponsoredStopPin(stop: stop) { selectedStop = stop }
                    }
                    .annotationTitles(.hidden)
                }
            }
            // Tap a hex to see why it's worth what it's worth. Taps on (or right next to) a pin belong to the pin.
            .onTapGesture { point in
                guard layer.showsHeat, let coordinate = proxy.convert(point, from: .local),
                      let cell = model.snapshot.cell(at: coordinate) else { return }
                let pins = (layer.showsPins ? model.snapshot.reports.map(\.coordinate) : []) + model.snapshot.stops.map(\.coordinate)
                let nearPin = pins.contains { pinCoordinate in
                    guard let pin = proxy.convert(pinCoordinate, to: .local) else { return false }
                    return hypot(pin.x - point.x, pin.y - point.y) < FLSpace.minTap / 2
                }
                if !nearPin { selectedCell = cell }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                region = context.region
                model.load(region: context.region)
            }
        }
        .task { locationManager.requestWhenInUseAuthorization() }
        .onChange(of: refreshToken) { model.load(region: region) }
        .safeAreaInset(edge: .top) { topBar }
        .overlay(alignment: .bottom) { captureButton }
        .sheet(item: $selected) { ReportPinSheet(report: $0) }
        .sheet(item: $selectedCell) { ZoneSheet(cell: $0) }
        // "Report an issue nearby" closes the sheet first; the camera cover presents once it's gone.
        .sheet(item: $selectedStop, onDismiss: {
            if captureAfterSheet { captureAfterSheet = false; onCapture() }
        }) { stop in
            CampaignSheet(stop: stop, location: { locationManager.location }, onReport: {
                captureAfterSheet = true
                selectedStop = nil
            })
        }
        .sheet(isPresented: $showList) {
            NearbyList(snapshot: model.snapshot, origin: locationManager.location?.coordinate ?? region.center) { coordinate in
                showList = false
                position = .region(MKCoordinateRegion(center: coordinate, span: .init(latitudeDelta: 0.012, longitudeDelta: 0.012)))
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: FLSpace.sm) {
            Picker("Map layer", selection: $layer) {
                ForEach(MapLayer.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(FLSpace.xs)
            .glassEffect(.regular, in: .capsule)

            Button { showList = true } label: {
                Image(systemName: "list.bullet")
                    .font(.flHeadline)
                    .foregroundStyle(.flInk)
                    .frame(width: FLSpace.minTap, height: FLSpace.minTap)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .accessibilityLabel("Show nearby bounties and damage as a list")
        }
        .padding(.horizontal, FLSpace.gutter)
        .overlay(alignment: .bottom) { status.offset(y: FLSpace.minTap) }
    }

    @ViewBuilder private var status: some View {
        if model.loadFailed {
            Button("Couldn't load the map. Retry") { model.load(region: region) }
                .font(.flCaption.weight(.semibold))
                .foregroundStyle(.flInk)
                .padding(.horizontal, FLSpace.md)
                .frame(minHeight: FLSpace.minTap)
                .glassEffect(.regular.interactive(), in: .capsule)
        } else if model.isLoading, model.snapshot == MapSnapshot() {  // only while empty; 30 s reloads stay quiet
            ProgressView()
                .padding(FLSpace.sm)
                .glassEffect(.regular, in: .circle)
                .accessibilityLabel("Loading map")
        }
    }

    private var captureButton: some View {
        let paused = inDangerArea
        return VStack(spacing: FLSpace.sm) {
            if paused {
                StatusBanner(status: .dangerZone, detail: "You're inside an active danger area. Get somewhere safe first. Nothing here earns points.")
                    .padding(.horizontal, FLSpace.gutter)
            }
            Button(action: onCapture) {
                Image(systemName: "camera.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.flOnBrand)
                    .frame(width: 64, height: 64)
                    .background(.flBrand, in: .circle)
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            }
            .disabled(paused)
            .opacity(paused ? 0.4 : 1)
            .accessibilityLabel("Report damage")
            .accessibilityHint(paused ? "Paused inside a danger area" : "")
        }
        .padding(.bottom, FLSpace.lg)
    }
}

/// Bounty name + multiplier, anchored on the bounty's north edge.
struct BountyLabel: View {
    let bounty: MapBounty
    var showsName = true

    var body: some View {
        HStack(spacing: FLSpace.xs) {
            MultiplierChip(multiplier: bounty.multiplier)
            if bounty.isSurge {
                Label("Surge", systemImage: "exclamationmark.triangle.fill")
                    .font(.flCaption.weight(.semibold)).foregroundStyle(.flDanger)
            }
            if showsName {
                Text(bounty.name).font(.flCaption.weight(.semibold)).foregroundStyle(.flInk).lineLimit(1)
            }
        }
        .padding(.leading, FLSpace.xs)
        .padding(.trailing, FLSpace.sm)
        .padding(.vertical, FLSpace.xs)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(bounty.name), \(bounty.isSurge ? "surge, " : "")\(bounty.multiplier.formatted()) times points")
    }
}

/// MASTER.md §6 MapPin: severity-colored circle with numeral, light ring; grows when selected.
struct DamagePin: View {
    let report: MapReport
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if report.fixedAt != nil { Image(systemName: "checkmark") } else { Text(report.severity.map(String.init) ?? "?") }
            }
                .font(.flCaption.weight(.heavy).monospacedDigit())
                .foregroundStyle(.flOnSeverity)
                .frame(width: 28, height: 28)
                .background(report.fixedAt != nil ? Color.flSuccess : report.severityLevel?.color ?? Severity.cosmetic.color, in: .circle)
                .overlay(Circle().strokeBorder(.flOnMedia, lineWidth: 2))
                .scaleEffect(isSelected ? 1.2 : 1)
                .animation(FLMotion.quick, value: isSelected)
                .frame(width: FLSpace.minTap, height: FLSpace.minTap)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(report.fixedAt != nil ? "\(report.typeLabel), fixed"
                            : "\(report.typeLabel), \(report.severityLevel?.accessibilityText ?? "severity unknown")")
        .accessibilityHint("Shows report details")
    }
}

struct ReportPinSheet: View {
    let report: MapReport

    var body: some View {
        VStack(alignment: .leading, spacing: FLSpace.md) {
            HStack(spacing: FLSpace.sm) {
                if let severity = report.severityLevel { SeverityBadge(severity: severity) }
                Spacer(minLength: 0)
            }
            Text(report.typeLabel).font(.flTitle).foregroundStyle(.flInk)
            Text("Reported \(report.createdAt, format: .relative(presentation: .named))")
                .font(.flCallout)
                .foregroundStyle(.flInk2)
            if let fixedAt = report.fixedAt {
                StatusBanner(status: .fixed, detail: "Repaired \(fixedAt.formatted(.relative(presentation: .named))).")
            } else if report.status == "review" {
                StatusBanner(status: .review)
            }
            Spacer(minLength: 0)
        }
        .padding(FLSpace.gutter)
        .presentationDetents([.height(240), .medium])
    }
}

/// "Why is this block worth 3×?" The same lines the server prices with (MASTER §9: rewards are explained).
struct ZoneSheet: View {
    let cell: HeatCell

    var body: some View {
        VStack(alignment: .leading, spacing: FLSpace.md) {
            if cell.danger {
                StatusBanner(status: .dangerZone, detail: "No points here until it's declared safe. Please stay out.")
            } else {
                HStack(spacing: FLSpace.sm) {
                    MultiplierChip(multiplier: cell.multiplier)
                    if cell.surge {
                        Label("Surge", systemImage: "exclamationmark.triangle.fill")
                            .font(.flCaption.weight(.semibold)).foregroundStyle(.flDanger)
                    }
                    Spacer(minLength: 0)
                }
                Text(cell.name ?? "Bounty zone").font(.flTitle).foregroundStyle(.flInk)
                Text("Reports on this block earn \(cell.multiplier.formatted())× points right now.")
                    .font(.flCallout).foregroundStyle(.flInk2)
                VStack(alignment: .leading, spacing: FLSpace.xs) {
                    ForEach(cell.why, id: \.self) { line in
                        Label(line, systemImage: "plus.forwardslash.minus").font(.flCallout.monospacedDigit()).foregroundStyle(.flInk)
                    }
                }
                Text("Prices move as reports come in: quiet blocks pay more, busy ones cool down. You get the price at the moment you submit.")
                    .font(.flCaption).foregroundStyle(.flInk2)
            }
            Spacer(minLength: 0)
        }
        .padding(FLSpace.gutter)
        .presentationDetents([.height(320), .medium])
    }
}

/// A sponsored store (CLAUDE.md §9.1): brand-blue storefront pin, never gold (MASTER §3.1: gold = zone pay).
struct SponsoredStopPin: View {
    let stop: CampaignStop
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "storefront.fill")
                .font(.flCaption.weight(.bold))
                .foregroundStyle(.flOnBrand)
                .frame(width: 30, height: 30)
                .background(.flBrand, in: .circle)
                .overlay(Circle().strokeBorder(.flOnMedia, lineWidth: 2))
                .frame(width: FLSpace.minTap, height: FLSpace.minTap)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sponsored: \(stop.title) at \(stop.name). \(stop.offer)")
        .accessibilityHint("Shows how to earn it")
    }
}

/// Sponsored quest at one store: 1) report a real issue within the radius, 2) check in within 75 m, 3) show the code.
/// Everything is decided server-side (`campaign_check_in()`); this sheet shows the steps and the result.
struct CampaignSheet: View {
    let stop: CampaignStop
    let location: () -> CLLocation?
    let onReport: () -> Void

    @Environment(GameModel.self) private var game
    @State private var busy = false
    @State private var result: CheckIn?
    @State private var failure: String?

    private var store: SponsoredCampaign.Store? { game.campaign(stop.campaignId)?.store(stop.id) }
    private var code: String? { result?.code ?? store?.code }
    private var qualified: Bool { store?.qualified == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FLSpace.lg) {
                VStack(alignment: .leading, spacing: FLSpace.xs) {
                    Label("Sponsored by \(stop.sponsor)", systemImage: "storefront.fill")
                        .font(.flCaption.weight(.semibold)).foregroundStyle(.flInk2)
                    Text(stop.title).font(.flTitle).foregroundStyle(.flInk)
                    Text(stop.name).font(.flCallout).foregroundStyle(.flInk2)
                }
                HStack(spacing: FLSpace.sm) {
                    Label(stop.offer, systemImage: "gift.fill").font(.flHeadline).foregroundStyle(.flInk)
                    Spacer(minLength: 0)
                    if stop.bonusPoints > 0 { PointsPill(points: stop.bonusPoints) }
                }

                if let code {
                    StatusBanner(status: .accepted, detail: store?.redeemedAt != nil ? "Already used at the till." : "Show this code at the till.")
                    Text(code)
                        .font(.flDisplay.monospaced())
                        .foregroundStyle(.flInk)
                        .frame(maxWidth: .infinity)
                        .textSelection(.enabled)
                        .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
                    if let bonus = result?.bonusPoints, bonus > 0 {
                        Text("+\(bonus) bonus points pending.").font(.flCallout).foregroundStyle(.flGoldText)
                    }
                } else {
                    step(1, done: qualified, "Report a real issue within \(stop.radiusM) m of the store.")
                    step(2, done: false, "Check in when you're at the store (within 75 m).")
                    if let message = failure ?? result?.error {
                        StatusBanner(status: .failed, detail: message)
                    }
                    if qualified {
                        Button(busy ? "Checking in…" : "Check in") { Task { await checkIn() } }
                            .buttonStyle(.flPrimary)
                            .disabled(busy)
                    } else {
                        Button("Report an issue nearby", action: onReport).buttonStyle(.flPrimary)
                    }
                }
                Text("One visit per store. The sponsor pays FaultLine for verified visits, never for your report data or who you are.")
                    .font(.flCaption).foregroundStyle(.flInk2)
            }
            .padding(FLSpace.gutter)
        }
        .presentationDetents([.medium, .large])
        .sensoryFeedback(.success, trigger: result?.ok == true)
        .task { await game.loadCampaigns() }
    }

    private func step(_ n: Int, done: Bool, _ text: String) -> some View {
        Label {
            Text(text).font(.flBody).foregroundStyle(.flInk)
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle").foregroundStyle(done ? .flSuccess : .flInk2)
        }
        .accessibilityLabel("Step \(n), \(done ? "done" : "to do"): \(text)")
    }

    private func checkIn() async {
        guard let here = location() else {
            failure = "Turn on location for FaultLine to check in."
            return
        }
        busy = true
        defer { busy = false }
        do {
            result = try await game.checkIn(store: stop.id, latitude: here.coordinate.latitude, longitude: here.coordinate.longitude)
            failure = nil
        } catch {
            failure = "Couldn't reach FaultLine. Try again."
        }
    }
}

#Preview { MapScreen(onCapture: {}, refreshToken: 0) }
