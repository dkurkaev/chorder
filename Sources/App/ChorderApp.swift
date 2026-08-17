import SwiftData
import SwiftUI

@main
struct ChorderApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .modelContainer(for: SongRecord.self)
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            RecordView()
                .tabItem { Label("Слушать", systemImage: "waveform") }
            LibraryView()
                .tabItem { Label("Записи", systemImage: "list.bullet") }
        }
    }
}
