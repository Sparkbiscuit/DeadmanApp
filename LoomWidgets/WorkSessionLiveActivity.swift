import ActivityKit
import WidgetKit
import SwiftUI

/// Lock Screen banner and Dynamic Island presentation for a running work
/// session. The timer renders via `Text(_, style: .timer)`, so it ticks
/// without any updates from the app.
struct WorkSessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkSessionAttributes.self) { context in
            LockScreenSessionView(context: context)
                .activityBackgroundTint(Color(red: 0.07, green: 0.07, blue: 0.08).opacity(0.92))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(context.attributes.contextColor)
                        Text(context.attributes.contextName)
                            .font(.custom("Nunito-Bold", size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.startedAt, style: .timer)
                        .font(.custom("JetBrainsMono-SemiBold", size: 15))
                        .foregroundStyle(context.attributes.contextColor)
                        .frame(maxWidth: 60, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.attributes.taskTitle)
                            .font(.custom("Nunito-Bold", size: 16))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text("Working · \(budgetLabel(context.attributes.effortMinutes)) budget")
                            .font(.custom("Nunito-SemiBold", size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "timer")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(context.attributes.contextColor)
            } compactTrailing: {
                Text(context.state.startedAt, style: .timer)
                    .font(.custom("JetBrainsMono-SemiBold", size: 13))
                    .foregroundStyle(context.attributes.contextColor)
                    .frame(maxWidth: 52)
                    .multilineTextAlignment(.trailing)
            } minimal: {
                Image(systemName: "timer")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(context.attributes.contextColor)
            }
            .keylineTint(context.attributes.contextColor)
        }
    }

    private func budgetLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60
        let m = minutes % 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }
}

// MARK: - Lock Screen view

private struct LockScreenSessionView: View {
    let context: ActivityViewContext<WorkSessionAttributes>

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 2)
                .fill(context.attributes.contextColor)
                .frame(width: 4, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(context.attributes.taskTitle)
                    .font(.custom("Nunito-Bold", size: 16))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(context.attributes.contextColor)
                        .frame(width: 6, height: 6)
                    Text("Working · \(context.attributes.contextName)")
                        .font(.custom("Nunito-SemiBold", size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            Spacer()

            Text(context.state.startedAt, style: .timer)
                .font(.custom("JetBrainsMono-SemiBold", size: 30))
                .foregroundStyle(context.attributes.contextColor)
                .frame(maxWidth: 110, alignment: .trailing)
                .multilineTextAlignment(.trailing)
        }
        .padding(16)
    }
}
