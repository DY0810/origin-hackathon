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
    @State private var showList = false

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
        .onChange(of: refreshToken) { model.load(region: region) }
        .safeAreaInset(edge: .top) { topBar }
        .overlay(alignment: .bottom) { captureButton }
        .sheet(item: $selected) { ReportPinSheet(report: $0) }
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
        Button(action: onCapture) {
            Image(systemName: "camera.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.flOnBrand)
                .frame(width: 64, height: 64)
                .background(.flBrand, in: .circle)
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        }
        .accessibilityLabel("Report damage")
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

#Preview { MapScreen(onCapture: {}, refreshToken: 0) }
