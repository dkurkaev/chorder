import SwiftData
import SwiftUI

struct RecordView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var analysisQueue: AnalysisQueue
    @EnvironmentObject private var router: AppRouter
    @StateObject private var recorder = AudioRecorder()

    @State private var toast: ToastMessage?
    @State private var isPressing = false
    @State private var dismissWorkItem: DispatchWorkItem?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Theme.background.ignoresSafeArea()

                VStack(spacing: 24) {
                    header
                    Spacer(minLength: 0)
                    recorderDial
                    timer
                    Spacer(minLength: 0)
                    hint
                }
                .padding(24)

                if let toast {
                    ToastView(message: toast) {
                        if let recordID = toast.recordID {
                            dismissToast()
                            router.open(recordID: recordID)
                        }
                    }
                    .padding(.horizontal, 20)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
                }
            }
            .navigationBarHidden(true)
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

    /// Кнопка записи в кольце живого спектра.
    private var recorderDial: some View {
        ZStack {
            RadialSpectrumView(levels: recorder.spectrum, isActive: recorder.isRecording)
                .frame(width: 300, height: 300)
            recordButton
        }
        .frame(width: 300, height: 300)
    }

    /// Запись идёт, пока кнопка удерживается.
    private var recordButton: some View {
        ZStack {
            Circle()
                .fill(Theme.accent.opacity(0.16))
                .frame(width: 160, height: 160)
                .scaleEffect(1 + CGFloat(recorder.level) * 0.18)
                .animation(.easeOut(duration: 0.12), value: recorder.level)
            Circle()
                .fill(recorder.isRecording ? Theme.accentWarm : Theme.accent)
                .frame(width: 116, height: 116)
            Image(systemName: recorder.isRecording ? "waveform" : "mic.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.black.opacity(0.85))
                .symbolEffect(.variableColor.iterative, isActive: recorder.isRecording)
        }
        .scaleEffect(isPressing ? 0.94 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressing)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressing else { return }
                    isPressing = true
                    start()
                }
                .onEnded { _ in
                    isPressing = false
                    stop()
                }
        )
    }

    private var timer: some View {
        Text(recorder.elapsed.asTimecode)
            .font(.system(size: 30, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(recorder.isRecording ? Theme.textPrimary : Theme.textSecondary)
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
                Text("Слушаю… отпусти, когда хватит")
            default:
                Text("Держи кнопку, пока играет музыка")
            }
        }
        .font(.footnote)
        .multilineTextAlignment(.center)
        .foregroundStyle(Theme.textSecondary)
        .frame(height: 40)
    }

    // MARK: - Действия

    private func start() {
        guard !recorder.isRecording else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        recorder.start()
    }

    private func stop() {
        guard recorder.isRecording else {
            recorder.cancel()   // отпустили до того, как запись успела начаться
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        recorder.stopAndSave { samples, url, duration in
            guard duration > 1 else {
                AudioFileStore.shared.delete(fileName: url?.lastPathComponent)
                show(ToastMessage(
                    icon: "exclamationmark.triangle",
                    title: "Слишком короткий фрагмент",
                    subtitle: "Подержи кнопку хотя бы пару секунд"
                ))
                return
            }

            let record = SongRecord(title: defaultTitle, duration: duration, audioURL: url)
            modelContext.insert(record)
            try? modelContext.save()

            analysisQueue.enqueue(
                recordID: record.id,
                samples: samples,
                sampleRate: AudioRecorder.sampleRate,
                container: modelContext.container
            )

            show(ToastMessage(
                icon: "checkmark.circle.fill",
                title: "Запись создана",
                subtitle: "Разбираю аккорды и ритм — нажми, чтобы открыть",
                recordID: record.id
            ))
        }
    }

    private func show(_ message: ToastMessage) {
        dismissWorkItem?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            toast = message
        }
        let work = DispatchWorkItem {
            if toast?.id == message.id { dismissToast() }
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func dismissToast() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            toast = nil
        }
    }

    private var defaultTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM, HH:mm"
        formatter.locale = Locale(identifier: "ru_RU")
        return formatter.string(from: Date())
    }
}

// MARK: - Уведомление

struct ToastMessage: Equatable, Identifiable {
    var id = UUID()
    var icon: String
    var title: String
    var subtitle: String
    var recordID: UUID?
}

struct ToastView: View {
    let message: ToastMessage
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: message.icon)
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(message.subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if message.recordID != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(14)
            .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(message.recordID == nil)
    }
}
