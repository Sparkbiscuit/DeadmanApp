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

/// The ring's fill window: worked time over the scheduled block's duration.
/// `ringEndsAt` is precomputed by the controller; the effort budget covers
/// activities started before it existed.
private func ringInterval(
    _ context: ActivityViewContext<WorkSessionAttributes>
) -> ClosedRange<Date> {
    let start = context.state.startedAt
    let end = context.attributes.ringEndsAt
        ?? start.addingTimeInterval(TimeInterval(context.attributes.effortMinutes * 60))
    // A degenerate window would crash the range; hold at least one minute.
    return start...max(end, start.addingTimeInterval(60))
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
            // Held-flame ring around the live timer. The arc is the system's
            // self-updating timer ring: empty at session start, full when the
            // scheduled block's worth of work is done — Live Activities can't
            // run code while locked, so only the system styles tick on their
            // own. Two accepted limits follow: past the block it holds full
            // (the in-app ring loops), and like the timer text beside it, it
            // keeps advancing through a pause.
            ZStack {
                // Static halo — Live Activities can't run continuous
                // animations, so the flame is held at a warm moment.
                Circle()
                    .fill(accent.color.opacity(0.3))
                    .blur(radius: 10)
                    .padding(-6)
                    .accessibilityHidden(true)

                ProgressView(
                    timerInterval: ringInterval(context),
                    countsDown: false,
                    label: { EmptyView() },
                    currentValueLabel: { EmptyView() }
                )
                .progressViewStyle(.circular)
                .tint(accent.color)
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

            // Held-flame mark — tapping the activity opens the timer, so the
            // glyph must not promise an inline action (pause) it can't do.
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [accent.hi, accent.color],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                    .shadow(color: accent.color.opacity(0.5), radius: 8)
                Image(systemName: "flame.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
        }
        .padding(16)
        // The hearth banked in the corner behind the flame, with a few
        // frozen ember sparks — same language as the widgets.
        .background {
            ZStack {
                RadialGradient(
                    colors: [accent.color.opacity(0.38), .clear],
                    center: UnitPoint(x: 0.12, y: 1.1),
                    startRadius: 0,
                    endRadius: 240
                )
                GeometryReader { geo in
                    ForEach(Array(Self.sparks.enumerated()), id: \.offset) { _, spark in
                        Circle()
                            .fill(accent.soft)
                            .frame(width: spark.size, height: spark.size)
                            .blur(radius: 0.5)
                            .shadow(color: accent.color.opacity(0.7), radius: 3)
                            .opacity(spark.alpha)
                            .position(
                                x: spark.x * geo.size.width,
                                y: spark.y * geo.size.height
                            )
                    }
                }
            }
            .accessibilityHidden(true)
        }
    }

    /// Deterministic spark positions (unit coordinates).
    private static let sparks: [(x: CGFloat, y: CGFloat, size: CGFloat, alpha: Double)] = [
        (0.12, 0.75, 2.5, 0.5),
        (0.3, 0.55, 2.0, 0.35),
        (0.55, 0.8, 2.5, 0.45),
        (0.72, 0.35, 2.0, 0.3)
    ]

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}
