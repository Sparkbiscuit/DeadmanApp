import ActivityKit
import WidgetKit
import SwiftUI

/// Lock Screen banner and Dynamic Island presentation for a running work
/// session, in the Hearthlight "held flame" language: a glowing ring around a
/// live mono timer, "Weaving now", and the block-end anchor. The timer renders
/// via the system timer text styles, so it ticks without app updates.
struct WorkSessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkSessionAttributes.self) { context in
            LockScreenSessionView(context: context)
                .activityBackgroundTint(Color(red: 0.07, green: 0.07, blue: 0.08).opacity(0.94))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let accent = HearthAccent.current
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(accent.soft)
                        Text(context.attributes.contextName)
                            .font(.custom("Nunito-Bold", size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    timerText(context, size: 15)
                        .foregroundStyle(accent.soft)
                        .frame(maxWidth: 64, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.attributes.taskTitle)
                            .font(.custom("Nunito-ExtraBold", size: 16))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(subtitle(context))
                            .font(.custom("Nunito-SemiBold", size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "flame.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent.soft)
            } compactTrailing: {
                timerText(context, size: 13)
                    .foregroundStyle(accent.soft)
                    .frame(maxWidth: 56)
                    .multilineTextAlignment(.trailing)
            } minimal: {
                Image(systemName: "flame.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent.soft)
            }
            .keylineTint(accent.color)
        }
    }
}

/// Counts down to the block end when the session started inside a block,
/// otherwise counts the session up.
private func timerText(
    _ context: ActivityViewContext<WorkSessionAttributes>,
    size: CGFloat
) -> some View {
    Group {
        if let end = context.attributes.blockEndsAt, end > context.state.startedAt {
            Text(timerInterval: context.state.startedAt...end, countsDown: true)
        } else {
            Text(context.state.startedAt, style: .timer)
        }
    }
    .font(.custom("JetBrainsMono-SemiBold", size: size))
    .monospacedDigit()
}

private func subtitle(_ context: ActivityViewContext<WorkSessionAttributes>) -> String {
    if let end = context.attributes.blockEndsAt {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return "Weaving now · block ends \(formatter.string(from: end))"
    }
    let minutes = context.attributes.effortMinutes
    let budget = minutes < 60
        ? "\(minutes)m"
        : minutes % 60 > 0 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes / 60)h"
    return "Weaving now · \(budget) budget"
}

// MARK: - Lock Screen view

private struct LockScreenSessionView: View {
    let context: ActivityViewContext<WorkSessionAttributes>

    var body: some View {
        let accent = HearthAccent.current

        HStack(spacing: 14) {
            // Held-flame ring around the live timer.
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: 0.62)
                    .stroke(
                        AngularGradient(
                            colors: [accent.soft, accent.color],
                            center: .center,
                            startAngle: .degrees(-90),
                            endAngle: .degrees(133)
                        ),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: accent.color.opacity(0.6), radius: 5)

                timerText(context, size: 13)
                    .foregroundStyle(.white)
                    .frame(maxWidth: 52)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
            }
            .frame(width: 62, height: 62)

            VStack(alignment: .leading, spacing: 2) {
                Text("WEAVING NOW")
                    .font(.custom("Nunito-Bold", size: 10))
                    .kerning(1.2)
                    .foregroundStyle(accent.soft)
                Text(context.attributes.taskTitle)
                    .font(.custom("Nunito-ExtraBold", size: 16))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let end = context.attributes.blockEndsAt {
                    Text("block ends \(end, formatter: Self.clockFormatter)")
                        .font(.custom("Nunito-SemiBold", size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                } else {
                    Text(context.attributes.contextName)
                        .font(.custom("Nunito-SemiBold", size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }

            Spacer()

            // Visual pause affordance — tapping the activity opens the timer.
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [accent.soft, accent.color],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                    .shadow(color: accent.color.opacity(0.5), radius: 8)
                Image(systemName: "pause.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .padding(16)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}
