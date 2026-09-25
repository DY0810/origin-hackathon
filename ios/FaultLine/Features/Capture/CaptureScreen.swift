import SwiftUI

struct CaptureScreen: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView("Camera", systemImage: "camera", description: Text("Capture flow: design-system/MASTER.md §7.1"))
                .background(.flCanvas)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                }
        }
    }
}

#Preview { CaptureScreen() }
