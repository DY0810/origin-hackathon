import MapKit
import SwiftUI

/// Accessible alternative to the map (MASTER.md §7.3): bounties and damage sorted by distance.
struct NearbyList: View {
    let snapshot: MapSnapshot
    let origin: CLLocationCoordinate2D
    let onSelect: (CLLocationCoordinate2D) -> Void

    var body: some View {
        NavigationStack {
            List {
                if !snapshot.dangers.isEmpty {
                    Section {
                        ForEach(snapshot.dangers.sorted { distance(to: $0.center) < distance(to: $1.center) }) { zone in
                            Button { onSelect(zone.center) } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: FLSpace.xs) {
                                        Text(zone.name).font(.flHeadline).foregroundStyle(.flInk)
                                        Text(zone.contains(origin) ? "You're inside it" : formatted(distance(to: zone.center)))
                                            .font(.flCallout).foregroundStyle(.flInk2)
                                    }
                                } icon: { Image(systemName: "flame.fill").foregroundStyle(.flDanger) }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityHint("Shows it on the map")
                        }
                    } header: { Text("Danger zones") } footer: { Text("No points, multipliers or quests inside. Stay out.") }
                }
                Section("Bounties") {
                    if snapshot.bounties.isEmpty {
                        Text("No bounties in this area.").foregroundStyle(.flInk2)
                    }
                    ForEach(snapshot.bounties.sorted { distance(to: $0) < distance(to: $1) }) { bounty in
                        Button { onSelect(bounty.coordinate) } label: {
                            HStack(spacing: FLSpace.md) {
                                VStack(alignment: .leading, spacing: FLSpace.xs) {
                                    Text(bounty.name).font(.flHeadline).foregroundStyle(.flInk)
                                    Text((bounty.isSurge ? "Surge · " : "") + formatted(distance(to: bounty))).font(.flCallout).foregroundStyle(.flInk2)
                                }
                                Spacer(minLength: 0)
                                MultiplierChip(multiplier: bounty.multiplier)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("Shows it on the map")
                    }
                }
                Section("Damage reports") {
                    if snapshot.reports.isEmpty {
                        Text("No reports in this area yet.").foregroundStyle(.flInk2)
                    }
                    ForEach(snapshot.reports.sorted { distance(to: $0.coordinate) < distance(to: $1.coordinate) }) { report in
                        Button { onSelect(report.coordinate) } label: {
                            HStack(spacing: FLSpace.md) {
                                VStack(alignment: .leading, spacing: FLSpace.xs) {
                                    Text(report.typeLabel).font(.flHeadline).foregroundStyle(.flInk)
                                    Text(formatted(distance(to: report.coordinate))).font(.flCallout).foregroundStyle(.flInk2)
                                }
                                Spacer(minLength: 0)
                                if let severity = report.severityLevel { SeverityBadge(severity: severity, showsLabel: false) }
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("Shows it on the map")
                    }
                }
            }
            .navigationTitle("Nearby")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    /// To the nearest heat cell of the bounty (its label sits on the far north edge), 0 when standing inside it.
    private func distance(to bounty: MapBounty) -> CLLocationDistance {
        let centers = snapshot.cells.filter { $0.bountyId == bounty.id }.map { cell in
            let points = cell.coordinates
            return CLLocationCoordinate2D(latitude: points.map(\.latitude).reduce(0, +) / Double(points.count),
                                          longitude: points.map(\.longitude).reduce(0, +) / Double(points.count))
        }
        let nearest = centers.map(distance(to:)).min() ?? distance(to: bounty.coordinate)
        return max(0, nearest - 100)  // ~ H3 res-9 cell radius
    }

    private func distance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    private func formatted(_ meters: CLLocationDistance) -> String {
        if meters < 50 { return "Right here" }
        return Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)) + " away"
    }
}
