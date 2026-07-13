import SwiftUI

// MARK: - Task Completion celebration

struct TaskCompletionView: View {
    let task: LoomTask
    var onDone: () -> Void
    /// Escape hatch for mis-taps: un-completes the task.
    var onUndo: (() -> Void)? = nil

    @State private var badgeScale: CGFloat = 0.4

    var body: some View {
        ZStack {
            HearthScreenBackground(topGlow: 0.24, bottomGlow: 0.3)

            ConfettiView(palette: [
                .schoolColor, .workColor, .personalColor,
                .brand500, .brand300, .loomRed
            ])
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            VStack(spacing: 0) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [task.context.displayColor, task.context.color],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 72, height: 72)
                        .hearthGlow(task.context.color, radius: 22, opacity: 0.55)
                    Image(systemName: "checkmark")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                }
                .scaleEffect(badgeScale)
                .padding(.bottom, 20)
                .accessibilityHidden(true)

                Text("Task Complete!")
                    .font(AppFont.title(26))
                    .foregroundStyle(LinearGradient.hearthTitle)
                    .padding(.bottom, 8)
                Text(task.title)
                    .font(AppFont.body(15))
                    .foregroundStyle(Color.loomSubtle)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 24)

                VStack(spacing: 10) {
                    if task.timeSpentMinutes > 0 {
                        statRow(
                            icon: "stopwatch",
                            label: "Time worked",
                            value: CountdownFormatter.effortString(minutes: task.timeSpentMinutes)
                        )
                    }
                    statRow(
                        icon: "calendar.badge.checkmark",
                        label: "Finished",
                        value: finishedLabel
                    )
                }
                .padding(.bottom, 32)

                Button {
                    onDone()
                } label: {
                    Text("Done")
                        .primaryButtonStyle(fill: task.context.color)
                }

                if let onUndo {
                    Button("Undo") {
                        onUndo()
                    }
                    .font(AppFont.caption(14))
                    .foregroundStyle(Color.loomSubtle)
                    .padding(.top, 14)
                }

                Spacer()
            }
            .padding(.horizontal, 32)
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) {
                badgeScale = 1.0
            }
        }
    }

    private var finishedLabel: String {
        let remaining = task.deadline.timeIntervalSince(Date())
        if remaining <= 0 { return "right on the wire" }
        let hours = Int(remaining) / 3600
        if hours >= 48 { return "\(hours / 24) days early" }
        if hours >= 1 { return "\(hours)h to spare" }
        return "\(max(1, Int(remaining) / 60))m to spare"
    }

    private func statRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(task.context.color)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(label)
                .font(AppFont.body(14))
                .foregroundStyle(Color.loomSubtle)
            Spacer()
            Text(value)
                .font(AppFont.mono(13))
                .foregroundStyle(Color.loomText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.loomSurface)
        .clipShape(RoundedRectangle(cornerRadius: LoomRadius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Confetti burst

/// Lightweight confetti: rectangles and dots fall from the top with slight
/// horizontal drift and spin. Purely decorative — one shot, no interaction.
struct ConfettiView: View {
    let palette: [Color]
    var pieceCount: Int = 60

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Piece {
        let x: Double          // 0…1 horizontal position
        let delay: Double
        let fallDuration: Double
        let size: Double
        let colorIndex: Int
        let isCircle: Bool
        let spin: Double       // total rotations
        let drift: Double      // horizontal wobble in points
    }

    @State private var pieces: [Piece] = []
    @State private var startDate = Date()
    @State private var finished = false

    var body: some View {
        Group {
            if reduceMotion {
                // A calm, still scatter instead of a continuous fall — the
                // celebration still reads, nothing keeps moving.
                Canvas { canvasContext, size in
                    draw(pieces, elapsed: 1.1, in: canvasContext, size: size)
                }
            } else {
                TimelineView(.animation(minimumInterval: nil, paused: finished)) { timeline in
                    Canvas { canvasContext, size in
                        let elapsed = timeline.date.timeIntervalSince(startDate)
                        draw(pieces, elapsed: elapsed, in: canvasContext, size: size)
                    }
                }
            }
        }
        .onAppear {
            startDate = Date()
            pieces = (0..<pieceCount).map { index in
                Piece(
                    x: .random(in: 0...1),
                    delay: .random(in: 0...0.6),
                    fallDuration: .random(in: 2.2...3.6),
                    size: .random(in: 6...11),
                    colorIndex: index,
                    isCircle: Bool.random(),
                    spin: .random(in: 1...3),
                    drift: .random(in: 12...36)
                )
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(5))
            finished = true
        }
    }

    private func draw(_ pieces: [Piece], elapsed: Double, in context: GraphicsContext, size: CGSize) {
        for piece in pieces {
            let t = (elapsed - piece.delay) / piece.fallDuration
            guard t > 0, t < 1.15 else { continue }

            let y = t * (size.height + 80) - 40
            let x = piece.x * size.width + sin(t * .pi * 3) * piece.drift
            let angle = Angle(degrees: t * 360 * piece.spin)
            let opacity = t > 0.9 ? max(0, 1 - (t - 0.9) / 0.25) : 1

            var ctx = context
            ctx.opacity = opacity
            ctx.translateBy(x: x, y: y)
            ctx.rotate(by: angle)

            let color = palette[piece.colorIndex % max(1, palette.count)]
            let rect = CGRect(
                x: -piece.size / 2, y: -piece.size / 2,
                width: piece.size, height: piece.isCircle ? piece.size : piece.size * 0.6
            )
            if piece.isCircle {
                ctx.fill(Path(ellipseIn: rect), with: .color(color))
            } else {
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color))
            }
        }
    }
}
