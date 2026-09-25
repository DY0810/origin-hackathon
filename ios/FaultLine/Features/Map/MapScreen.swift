import MapKit
import SwiftUI

struct MapScreen: View {
    let onCapture: () -> Void
    @State private var locationManager = CLLocationManager()

    var body: some View {
        Map(initialPosition: .userLocation(fallback: .automatic))
            .task { locationManager.requestWhenInUseAuthorization() }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .overlay(alignment: .bottom) {
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
}

#Preview { MapScreen(onCapture: {}) }
