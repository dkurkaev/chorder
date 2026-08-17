import SwiftData
import SwiftUI

@main
struct ChorderApp: App {
    @StateObject private var analysisQueue = AnalysisQueue()
    @StateObject private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(analysisQueue)
                .environmentObject(router)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .modelContainer(for: SongRecord.self)
    }
}

/// Навигация между вкладками: по тапу на уведомление открываем свежую запись.
final class AppRouter: ObservableObject {
    enum Tab: Hashable {
        case record
        case library
    }

    @Published var tab: Tab = .record
    @Published var recordToOpen: UUID?

    func open(recordID: UUID) {
        recordToOpen = recordID
        tab = .library
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        content
        #if DEBUG
            .task {
                guard DemoLibrary.isRequested else { return }
                DemoLibrary.seed(into: modelContext)
                if DemoLibrary.shouldOpenFirstRecord,
                   let first = try? modelContext.fetch(
                       FetchDescriptor<SongRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
                   ).first {
                    router.open(recordID: first.id)
                } else {
                    router.tab = .library
                }
            }
        #endif
    }

    private var content: some View {
        TabView(selection: $router.tab) {
            RecordView()
                .tabItem { Label("Слушать", systemImage: "waveform") }
                .tag(AppRouter.Tab.record)
            LibraryView()
                .tabItem { Label("Записи", systemImage: "list.bullet") }
                .tag(AppRouter.Tab.library)
        }
    }
}
