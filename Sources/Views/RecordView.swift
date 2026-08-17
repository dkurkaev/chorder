import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct RecordView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var analysisQueue: AnalysisQueue
    @EnvironmentObject private var router: AppRouter
    @StateObject private var recorder = AudioRecorder()

    @State private var banner: BannerMessage?
    @State private var isPressing = false
    @State private var dismissWorkItem: DispatchWorkItem?
    @State private var isFilePickerPresented = false
    @State private var isImporting = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Theme.background.ignoresSafeArea()

                VStack(spacing: 20) {
                    header
                    Spacer(minLength: 0)
                    recorderDial
                    timer
                    Spacer(minLength: 0)
                    importButton
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
        .fileImporter(
            isPresented: $isFilePickerPresented,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                startImport(from: url)
            case .failure(let error):
                showImportFailure(error)
            }
        }
        // Файл, переданный из Voice Memos или другого приложения через «Поделиться».
        .onChange(of: router.pendingImportURL) { _, url in
            guard let url else { return }
            router.pendingImportURL = nil
            startImport(from: url)
        }
        .onAppear {
            recorder.onMaxDurationReached = { stop() }
            if let url = router.pendingImportURL {
                router.pendingImportURL = nil
                startImport(from: url)
            }
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

    /// Разбор готового файла — быстрый способ прогнать алгоритм на одном и том же материале.
    private var importButton: some View {
        Button {
            isFilePickerPresented = true
        } label: {
            HStack(spacing: 8) {
                if isImporting {
                    ProgressView().controlSize(.small).tint(Theme.textPrimary)
                } else {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(isImporting ? "Разбираю файл" : "Импортировать файл")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 20)
            .frame(height: 46)
            .background(Theme.surfaceHigh, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isImporting || recorder.isRecording)
        .opacity(recorder.isRecording ? 0 : 1)
        .animation(.easeInOut(duration: 0.2), value: recorder.isRecording)
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

            let record = createRecord(
                title: defaultTitle, samples: samples, url: url, duration: duration
            )

            show(BannerMessage(
                icon: "checkmark.circle.fill",
                title: "Запись создана",
                subtitle: "Разбираю аккорды и ритм — нажми, чтобы открыть",
                recordID: record.id
            ))
        }
    }

    // MARK: - Импорт

    private func startImport(from url: URL) {
        guard !isImporting else { return }
        isImporting = true
        AudioImporter.load(from: url) { result in
            isImporting = false
            switch result {
            case .success(let imported):
                let record = createRecord(
                    title: imported.title,
                    samples: imported.samples,
                    url: imported.url,
                    duration: imported.duration
                )
                show(BannerMessage(
                    icon: "checkmark.circle.fill",
                    title: "Файл импортирован",
                    subtitle: imported.wasTrimmed
                        ? "Взял первую минуту — разбираю аккорды и ритм"
                        : "Разбираю аккорды и ритм — нажми, чтобы открыть",
                    recordID: record.id
                ))
            case .failure(let error):
                showImportFailure(error)
            }
        }
    }

    private func showImportFailure(_ error: Error) {
        show(BannerMessage(
            icon: "exclamationmark.triangle.fill",
            title: "Импорт не удался",
            subtitle: error.localizedDescription,
            isWarning: true
        ))
    }

    /// Общий путь для микрофона и импорта: запись появляется в библиотеке сразу,
    /// разбор дописывается по готовности.
    @discardableResult
    private func createRecord(
        title: String, samples: [Float], url: URL?, duration: Double
    ) -> SongRecord {
        let record = SongRecord(title: title, duration: duration, audioURL: url)
        modelContext.insert(record)
        try? modelContext.save()

        analysisQueue.enqueue(
            recordID: record.id,
            samples: samples,
            sampleRate: AudioRecorder.sampleRate,
            container: modelContext.container
        )
        return record
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
