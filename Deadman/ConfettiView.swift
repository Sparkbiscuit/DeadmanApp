import SwiftUI

struct ConfettiPiece: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    let color: Color
    let size: CGFloat
    let rotation: Double
    let speed: Double
    let wobble: Double
    let shape: Int // 0 = rect, 1 = circle, 2 = triangle
}

struct ConfettiView: View {
    @State private var pieces: [ConfettiPiece] = []
    @State private var animate = false
    let onComplete: () -> Void

    private let colors: [Color] = [
        .loomRed, .schoolColor, .workColor, .personalColor,
        .yellow, .pink, .purple, .mint, .orange, .cyan
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(pieces) { piece in
                    confettiShape(piece)
                        .offset(
                            x: animate
                                ? piece.x + CGFloat(sin(piece.wobble * 4) * 40)
                                : piece.x,
                            y: animate
                                ? geo.size.height + 50
                                : piece.y
                        )
                        .rotationEffect(.degrees(animate ? piece.rotation * 4 : 0))
                        .opacity(animate ? 0 : 1)
                }
            }
            .onAppear {
                generatePieces(in: geo.size)
                withAnimation(.easeOut(duration: 2.8)) {
                    animate = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    onComplete()
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func generatePieces(in size: CGSize) {
        pieces = (0..<60).map { _ in
            ConfettiPiece(
                x: CGFloat.random(in: -20...(size.width + 20)),
                y: CGFloat.random(in: -size.height * 0.5...(-10)),
                color: colors.randomElement()!,
                size: CGFloat.random(in: 5...10),
                rotation: Double.random(in: -180...180),
                speed: Double.random(in: 1.0...2.5),
                wobble: Double.random(in: 0.5...3.0),
                shape: Int.random(in: 0...2)
            )
        }
    }

    @ViewBuilder
    private func confettiShape(_ piece: ConfettiPiece) -> some View {
        switch piece.shape {
        case 0:
            Rectangle()
                .fill(piece.color)
                .frame(width: piece.size, height: piece.size * 1.4)
        case 1:
            Circle()
                .fill(piece.color)
                .frame(width: piece.size, height: piece.size)
        default:
            Triangle()
                .fill(piece.color)
                .frame(width: piece.size * 1.2, height: piece.size)
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Task Completion Sheet

struct TaskCompletionView: View {
    @Environment(\.colorScheme) private var colorScheme
    let task: LoomTask
    let onDismiss: () -> Void
    @State private var showConfetti = true

    var body: some View {
        ZStack {
            // Solid background so text is always legible
            (colorScheme == .dark ? Color(.systemBackground) : Color(.systemBackground))
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(task.context.color)
                    .symbolEffect(.bounce, value: true)

                VStack(spacing: 8) {
                    Text("Task Complete!")
                        .font(AppFont.title(28))
                        .foregroundStyle(.primary)

                    Text(task.title)
                        .font(AppFont.body())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                // Stats
                VStack(spacing: 12) {
                    if task.totalTimeSpentMinutes > 0 {
                        StatRow(
                            label: "Time spent",
                            value: CountdownFormatter.effortString(minutes: task.totalTimeSpentMinutes),
                            detail: "estimated \(CountdownFormatter.effortString(minutes: task.effortMinutes))",
                            color: task.isOverBudget ? .orange : task.context.color
                        )
                    }

                    if task.workSessions.count > 0 {
                        StatRow(
                            label: "Work sessions",
                            value: "\(task.workSessions.count)",
                            detail: nil,
                            color: task.context.color
                        )
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 8)

                Spacer()

                Button {
                    onDismiss()
                } label: {
                    Text("Done")
                        .font(AppFont.heading(17))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(task.context.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }

            if showConfetti {
                ConfettiView {
                    showConfetti = false
                }
            }
        }
        .onAppear {
            Haptics.notification(.success)
        }
    }
}

private struct StatRow: View {
    let label: String
    let value: String
    let detail: String?
    let color: Color

    var body: some View {
        HStack {
            Text(label)
                .font(AppFont.caption(14))
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 6) {
                Text(value)
                    .font(AppFont.mono(15))
                    .foregroundStyle(color)
                if let detail {
                    Text("(\(detail))")
                        .font(AppFont.mono(12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
