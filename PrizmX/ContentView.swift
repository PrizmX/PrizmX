import SwiftUI

/// Compatibility wrapper kept so existing project previews still compile.
struct ContentView: View {
    var body: some View {
        SurgeStyleMainWindow()
            .environment(AppModel.preview)
    }
}

#Preview {
    ContentView()
}
