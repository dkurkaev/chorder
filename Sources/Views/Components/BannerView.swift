import SwiftUI

struct BannerMessage: Equatable, Identifiable {
    var id = UUID()
    var icon: String
    var title: String
    var subtitle: String
    /// Если задан — по баннеру можно тапнуть и перейти к записи.
    var recordID: UUID?
    var isWarning = false
}

/// Внутренний баннер поверх экрана.
///
/// Системного API для таких уведомлений в iOS нет (`UserNotifications` — это пуши,
/// они требуют разрешения и показываются вне приложения), поэтому компонент свой.
/// Поведение повторяет системное: пружинная анимация, тянется за пальцем,
/// смахивается вверх, автоскрытие приостанавливается на время жеста.
struct BannerView: View {
    let message: BannerMessage
    var onTap: () -> Void
    var onDismiss: () -> Void
    var onDragChanged: (Bool) -> Void = { _ in }

    @State private var dragOffset: CGFloat = 0
    @GestureState private var isDragging = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 18, style: .continuous) }

    var body: some View {
        // Ручка захвата — часть потока, а не overlay: иначе она наезжает на текст.
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: message.icon)
                    .font(.system(size: 22))
                    .foregroundStyle(message.isWarning ? Theme.accentWarm : Theme.accent)

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

            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: 36, height: 4)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 9)
        .background(Theme.surfaceHigh, in: shape)
        .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        .contentShape(shape)
        .offset(y: dragOffset)
        .gesture(dragGesture)
        .onTapGesture {
            guard message.recordID != nil else { return }
            onTap()
        }
        .onChange(of: isDragging) { _, dragging in
            onDragChanged(dragging)
            if !dragging {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { dragOffset = 0 }
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                let translation = value.translation.height
                // Вверх — следует за пальцем, вниз — с сопротивлением.
                dragOffset = translation < 0 ? translation : translation * 0.2
            }
            .onEnded { value in
                let translation = value.translation.height
                let predicted = value.predictedEndTranslation.height
                if translation < -20 || predicted < -80 {
                    onDismiss()
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { dragOffset = 0 }
                }
            }
    }
}

extension AnyTransition {
    /// Плавный выезд сверху: смещение с запасом за край экрана + затухание,
    /// поэтому баннер не «обрезается» в момент исчезновения.
    static var banner: AnyTransition {
        .offset(y: -220).combined(with: .opacity)
    }
}
