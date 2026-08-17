import SwiftData
import SwiftUI

struct RecordView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var analysisQueue: AnalysisQueue
    @EnvironmentObject private var router: AppRouter
    @StateObject private var recorder = AudioRecorder()

    @State private var banner: BannerMessage?
    @State private var isPressing = false
    @State private var dismissWorkItem: DispatchWorkItem?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Theme.background.ignoresSafeArea()

                VStack(spacing: 20) {
                    header
                    Spacer(minLength: 0)
                    recorderDial
                    Spacer(minLength: 0)
                    timer
                    problem
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

                if let banner {
                    BannerView(
                        message: banner,
                        onTap: {
                            guard let recordID = banner.recordID else { return }
                            dismissBanner()
                            router.open(recordID: recordID)
                        },
                        onDismiss: { dismissBanner() },
                        onDragChanged: { isDragging in
                            // Пока баннер держат пальцем, автоскрытие не срабатывает.
                            if isDragging {
                                dismissWorkItem?.cancel()
                            } else {
                                scheduleDismiss(for: banner)
                            }
                        }
                    )
                    .padding(.horizontal, 16)
                    .transition(.banner)
                    .zIndex(10)
                }
            }
            .navigationBarHidden(true)
        }
        .onAppear {
            recorder.onMaxDurationReached = { stop() }
            #if DEBUG
            if CommandLine.arguments.contains("-simulateSpectrum") {
                recorder.startSimulation()
            }
            #endif
        }
    }

    // MARK: - Части экрана

    private var header: some View {
        Text("Chorder")
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.textPrimary)
    }

    /// Главный элемент экрана: крупная кнопка в живой пульсирующей форме.
    private var recorderDial: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let buttonSize = side * 0.62

            ZStack {
                PulseVisualizerView(
                    levels: recorder.spectrum,
                    isActive: recorder.isRecording,
                    innerRadius: buttonSize / 2 + 10,
                    maxLength: (side - buttonSize) / 2 - 14,
                    tint: recorder.isRecording ? Theme.accentWarm : Theme.accent,
                    tintComponents: recorder.isRecording
                        ? Theme.accentWarmComponents
                        : Theme.accentComponents
                )
                recordButton(size: buttonSize)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 380)
    }

    /// Запись идёт, пока кнопка удерживается.
    private func recordButton(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: recorder.isRecording
                            ? [Theme.accentWarm, Theme.accentWarm.opacity(0.55)]
                            : [Theme.accent, Theme.accent.opacity(0.55)],
                        center: UnitPoint(x: 0.32, y: 0.26),
                        startRadius: 0,
                        endRadius: size * 0.95
                    )
                )
                .overlay(
                    Circle().strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.35), .white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                )
                .shadow(
                    color: (recorder.isRecording ? Theme.accentWarm : Theme.accent).opacity(0.38),
                    radius: 26
                )

            Image(systemName: recorder.isRecording ? "waveform" : "mic.fill")
                .font(.system(size: size * 0.26, weight: .medium))
                .foregroundStyle(Color(red: 0.05, green: 0.06, blue: 0.09).opacity(0.9))
                .symbolEffect(.variableColor.iterative, isActive: recorder.isRecording)
        }
        .frame(width: size, height: size)
        .scaleEffect(isPressing ? 0.96 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressing)
        .animation(.easeInOut(duration: 0.2), value: recorder.isRecording)
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
            .font(.system(size: 60, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Theme.textPrimary)
            .opacity(recorder.isRecording ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: recorder.isRecording)
            .frame(height: 68)
    }

    /// Показывается только когда есть что сказать по делу.
    @ViewBuilder private var problem: some View {
        switch recorder.state {
        case .denied:
            problemText("Нет доступа к микрофону — включи его в Настройках")
        case .failed(let message):
            problemText(message)
        default:
            Color.clear.frame(height: 20)
        }
    }

    private func problemText(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .foregroundStyle(Theme.accentWarm)
            .frame(height: 20)
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
                show(BannerMessage(
                    icon: "exclamationmark.triangle.fill",
                    title: "Слишком короткий фрагмент",
                    subtitle: "Подержи кнопку хотя бы пару секунд",
                    isWarning: true
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

            show(BannerMessage(
                icon: "checkmark.circle.fill",
                title: "Запись создана",
                subtitle: "Разбираю аккорды и ритм — нажми, чтобы открыть",
                recordID: record.id
            ))
        }
    }

    private func show(_ message: BannerMessage) {
        dismissWorkItem?.cancel()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
            banner = message
        }
        scheduleDismiss(for: message)
    }

    private func scheduleDismiss(for message: BannerMessage) {
        dismissWorkItem?.cancel()
        let work = DispatchWorkItem {
            guard banner?.id == message.id else { return }
            dismissBanner()
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func dismissBanner() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) {
            banner = nil
        }
    }

    private var defaultTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM, HH:mm"
        formatter.locale = Locale(identifier: "ru_RU")
        return formatter.string(from: Date())
    }
}
