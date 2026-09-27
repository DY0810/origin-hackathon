import MapKit
import SwiftUI

/// Map tab (design-system/MASTER.md §7.3): bounty heat (gold H3 hexes) + damage pins, layer toggle,
/// list alternative, capture button. Danger zones (CLAUDE.md §6.8): red polygons, no multipliers, SafetyBanner, FAB paused.
struct MapScreen: View {
    let onCapture: () -> Void
    var onScan: () -> Void = {}
    /// Bumped by RootView after a capture closes, so a new report shows up.
    let refreshToken: Int

    // ponytail: USC fallback until the demo city is picked (CLAUDE.md §14).
    static let demoRegion = MKCoordinateRegion(center: .init(latitude: 34.0225, longitude: -118.2851),
                                               span: .init(latitudeDelta: 0.045, longitudeDelta: 0.045))

    private static let captureSize: CGFloat = 64                    // MASTER §6 CaptureButton
    private static let scanSize: CGFloat = FLSpace.minTap + FLSpace.sm  // secondary, smaller than the FAB

    @State private var locationManager = CLLocationManager()
    @State private var model = MapModel()
    @State private var layer: MapLayer = .both
    @State private var position: MapCameraPosition = .userLocation(fallback: .region(Self.demoRegion))
    @State private var region = Self.demoRegion
    @State private var selected: MapReport?
    @State private var showList = false
    @State private var dangerInfo = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Map(position: $position) {
            UserAnnotation()
            if layer.showsHeat {
                ForEach(model.snapshot.cells) { cell in
                    MapPolygon(coordinates: cell.coordinates)
                        .foregroundStyle(Color.flGold.opacity(HeatStyle.opacity(for: cell.multiplier)))
                        // ponytail: static dashed surge outline (MASTER §6 animates it); animating re-diffs every Map polygon, move to its own overlay if we want motion
                        .stroke(cell.isSurge ? Color.flDanger : Color.flGold.opacity(0.7),
                                style: cell.isSurge ? StrokeStyle(lineWidth: 2, dash: [4, 3]) : StrokeStyle(lineWidth: 0.5))
                }
                ForEach(model.snapshot.bounties.filter { !model.snapshot.inDanger($0.coordinate) }) { bounty in  // no multiplier inside danger
                    Annotation(bounty.name, coordinate: bounty.coordinate, anchor: .bottom) {
                        BountyLabel(bounty: bounty, showsName: layer == .bounties)  // names only when pins are hidden
                    }
                    .annotationTitles(.hidden)
                }
            }
            // Every layer: safety isn't a filter. ponytail: tinted fill, not MASTER's red hatch (MapPolygon takes a color only).
            ForEach(model.snapshot.dangers) { zone in
                MapPolygon(coordinates: zone.coordinates)
                    .foregroundStyle(Color.flDanger.opacity(0.2))
                    .stroke(Color.flDanger, lineWidth: 2)
                Annotation(zone.name, coordinate: .init(latitude: zone.coordinates.map(\.latitude).max() ?? zone.center.latitude,
                                                        longitude: zone.center.longitude), anchor: .bottom) {  // north edge, off the pins
                    Label(zone.name, systemImage: "flame.fill")
                        .font(.flCaption.weight(.semibold)).foregroundStyle(.flDanger).lineLimit(1)
                        .padding(.horizontal, FLSpace.sm).padding(.vertical, FLSpace.xs)
                        .glassEffect(.regular, in: .capsule)
                        .accessibilityLabel("Danger zone: \(zone.name). No rewards inside.")
                }
                .annotationTitles(.hidden)
            }
            if layer.showsPins {
                ForEach(PinCluster.make(model.snapshot.reports, region: region)) { cluster in
                    if cluster.reports.count == 1, let report = cluster.reports.first {
                        Annotation(report.typeLabel, coordinate: report.coordinate) {
                            DamagePin(report: report, isSelected: selected == report) { selected = report }
                        }
                        .annotationTitles(.hidden)
                    } else {
                        Annotation("\(cluster.reports.count) reports", coordinate: cluster.coordinate) {
                            ClusterPin(cluster: cluster) { zoom(into: cluster) }
                        }
                        .annotationTitles(.hidden)
                    }
                }
            }
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
        .task { locationManager.requestWhenInUseAuthorization() }
        .task {  // point-in-polygon against the loaded danger zones (MapModel.inDanger)
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    if let location = update.location { model.userLocation = location.coordinate }
                }
            } catch {}
        }
        .onChange(of: refreshToken) { model.load(region: region) }
        .safeAreaInset(edge: .top) { topBar }
        .overlay(alignment: .bottom) { captureButton }
        .overlay(alignment: .bottomTrailing) { scanButton }
        .sheet(item: $selected) { ReportPinSheet(report: $0) }
        .sheet(isPresented: $showList) {
            NearbyList(snapshot: model.snapshot, origin: locationManager.location?.coordinate ?? region.center) { coordinate in
                showList = false
                position = .region(MKCoordinateRegion(center: coordinate, span: .init(latitudeDelta: 0.012, longitudeDelta: 0.012)))
            }
        }
    }

    private var topBar: some View {
        VStack(spacing: FLSpace.sm) {
            layerBar
            SafetyBanner(isActive: model.inDanger)
        }
        .padding(.horizontal, FLSpace.gutter)
        .overlay(alignment: .bottom) { status.offset(y: FLSpace.minTap) }
    }

    private var layerBar: some View {
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
    }

    private func zoom(into cluster: PinCluster) {
        let span = MKCoordinateSpan(latitudeDelta: region.span.latitudeDelta / 3, longitudeDelta: region.span.longitudeDelta / 3)
        withAnimation(FLMotion.resolve(FLMotion.standard, reduceMotion)) { position = .region(.init(center: cluster.coordinate, span: span)) }
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

    /// MASTER §6 CaptureButton: "disabled in danger zone (with reason on tap)", so it stays tappable and explains.
    private var captureButton: some View {
        Button { if model.inDanger { dangerInfo = true } else { onCapture() } } label: {
            Image(systemName: model.inDanger ? "camera.badge.ellipsis" : "camera.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.flOnBrand)
                .frame(width: Self.captureSize, height: Self.captureSize)
                .background(model.inDanger ? Color.flInk3 : Color.flBrand, in: .circle)
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        }
        .accessibilityLabel("Report damage")
        .accessibilityValue(model.inDanger ? "Paused in a danger zone" : "")
        .accessibilityHint(model.inDanger ? "Explains why reporting is paused" : "")
        .padding(.bottom, FLSpace.lg)
        .alert("Reporting is paused here", isPresented: $dangerInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You're inside a danger zone. FaultLine doesn't reward reports here so nobody is drawn toward danger. Move somewhere safe to report.")
        }
    }

    /// MASTER §7.3: "Scan my photos" as a secondary floating control.
    private var scanButton: some View {
        Button(action: onScan) {
            Image(systemName: "photo.stack")
                .font(.flHeadline)
                .foregroundStyle(.flInk)
                .frame(width: Self.scanSize, height: Self.scanSize)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .accessibilityLabel("Scan my photos")
        .accessibilityHint("Finds damage in photos you already took, on your iPhone")
        .padding(.trailing, FLSpace.gutter)
        .padding(.bottom, FLSpace.lg + (Self.captureSize - Self.scanSize) / 2)  // centered on the capture button
    }
}

/// MASTER.md §6 SafetyBanner: StatusBanner .dangerZone pinned at the top of the map / camera.
/// Entering posts a VoiceOver announcement and an `.error` haptic (MASTER §3.5), once per entry.
struct SafetyBanner: View {
    let isActive: Bool
    static let detail = "No points or quests inside. Leave the area and follow official instructions."

    var body: some View {
        VStack {
            if isActive { StatusBanner(status: .dangerZone, detail: Self.detail) }
        }
        .sensoryFeedback(.error, trigger: isActive) { _, entered in entered }
        .onChange(of: isActive, initial: true) { _, entered in
            if entered { AccessibilityNotification.Announcement("Danger zone. \(ReportStatus.dangerZone.text) \(Self.detail)").post() }
        }
    }
}

/// MASTER.md §6 MapPin cluster: count ringed in the highest open severity's color (success when all fixed); tap zooms in.
struct ClusterPin: View {
    let cluster: PinCluster
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(cluster.reports.count)")
                .font(.flCaption.weight(.heavy).monospacedDigit())
                .foregroundStyle(.flInk)
                .frame(width: 36, height: 36)
                .background(.flSurface, in: .circle)  // light fill so a count never reads as a severity numeral
                .overlay(Circle().strokeBorder(cluster.topSeverity?.color ?? .flSuccess, lineWidth: 4))
                .frame(width: FLSpace.minTap, height: FLSpace.minTap)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(cluster.reports.count) reports, " + (cluster.topSeverity.map { "worst \($0.accessibilityText)" } ?? "all fixed"))
        .accessibilityHint("Zooms in")
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

#Preview { MapScreen(onCapture: {}, refreshToken: 0) }
