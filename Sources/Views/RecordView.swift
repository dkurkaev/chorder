import SwiftData
import SwiftUI

struct RecordView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var recorder = AudioRecorder()
    @State private var pendingResult: AnalysisResult?
    @State private var pendingAudioURL: URL?
    @State private var showResult = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 20) {
                    header
                    Spacer(minLength: 8)
                    liveReadout
                    visualizer
                    Spacer(minLength: 8)
                    recordButton
                    hint
                }
                .padding(24)

                if recorder.state == .analyzing {
                    analyzingOverlay
                }
            }
            .navigationBarHidden(true)
        }
        .sheet(isPresented: $showResult) {
            if let pendingResult {
                NavigationStack {
                    AnalysisView(
                        result: pendingResult,
                        audioURL: pendingAudioURL,
                        title: defaultTitle,
                        onSave: { title in
                            save(result: pendingResult, audioURL: pendingAudioURL, title: title)
                            showResult = false
                        },
                        onDiscard: {
                            AudioFileStore.shared.delete(fileName: pendingAudioURL?.lastPathComponent)
                            showResult = false
                        }
                    )
                }
            }
        }
        .onAppear {
            recorder.onMaxDurationReached = { stop() }
        }
    }

    // MARK: - Части экрана

    private var header: some View {
        VStack(spacing: 6) {
            Text("Chorder")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text("Поднеси телефон к музыке")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var liveReadout: some View {
        VStack(spacing: 18) {
            Text(recorder.liveChord.isNone ? "—" : recorder.liveChord.name)
                .font(.system(size: 76, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.color(for: recorder.liveChord))
                .contentTransition(.numericText())
                .animation(.spring(response: 0.3), value: recorder.liveChord)

            HStack(spacing: 26) {
                metric(value: recorder.liveBPM > 0 ? String(format: "%.0f", recorder.liveBPM) : "—", caption: "BPM")
                metric(value: recorder.elapsed.asTimecode, caption: "запись")
            }
        }
    }

    private var visualizer: some View {
        VStack(spacing: 12) {
            SpectrumView(levels: recorder.spectrum, isActive: recorder.isRecording)
                .frame(height: 110)
            ChromaStripView(values: recorder.chroma, chord: recorder.liveChord)
        }
        .padding(.horizontal, 4)
    }

    private func metric(value: String, caption: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var recordButton: some View {
        Button {
            if recorder.isRecording { stop() } else { recorder.start() }
        } label: {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.16))
                    .frame(width: 168, height: 168)
                    .scaleEffect(1 + CGFloat(recorder.level) * 0.35)
                    .animation(.easeOut(duration: 0.12), value: recorder.level)
                Circle()
                    .fill(recorder.isRecording ? Theme.accentWarm : Theme.accent)
                    .frame(width: 116, height: 116)
                Image(systemName: recorder.isRecording ? "stop.fill" : "waveform")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.85))
            }
        }
        .buttonStyle(.plain)
        .disabled(recorder.state == .analyzing)
    }

    private var hint: some View {
        Group {
            switch recorder.state {
            case .denied:
                Text("Нет доступа к микрофону. Включи его в Настройках → Chorder.")
                    .foregroundStyle(Theme.accentWarm)
            case .failed(let message):
                Text(message).foregroundStyle(Theme.accentWarm)
            case .recording:
                Text("Слушаю… 10–30 секунд обычно достаточно")
            default:
                Text("Нажми и дай приложению послушать фрагмент")
            }
        }
        .font(.footnote)
        .multilineTextAlignment(.center)
        .foregroundStyle(Theme.textSecondary)
        .frame(height: 40)
    }

    private var analyzingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(Theme.accent)
                Text("Разбираю аккорды и ритм…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(28)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    // MARK: - Действия

    private func stop() {
        guard recorder.isRecording else { return }
        recorder.stopAndAnalyze { result, url in
            pendingResult = result
            pendingAudioURL = url
            showResult = true
        }
    }

    private var defaultTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM, HH:mm"
        formatter.locale = Locale(identifier: "ru_RU")
        return "Фрагмент \(formatter.string(from: Date()))"
    }

    private func save(result: AnalysisResult, audioURL: URL?, title: String) {
        let record = SongRecord(title: title, result: result, audioURL: audioURL)
        modelContext.insert(record)
        try? modelContext.save()
    }
}
