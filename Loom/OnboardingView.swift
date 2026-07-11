import SwiftUI
import SwiftData

/// First-launch flow: introduces the core idea, then collects the scheduling
/// basics (wake/sleep, block sizes, deadline buffer) pre-filled with defaults.
/// Completion flips `hasCompletedOnboarding`; there is no other way out.
struct OnboardingView: View {
    let settings: UserSettings

    @State private var step = 0
    private let stepCount = 4

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            Group {
                switch step {
                case 0: welcomeStep
                case 1: dayStep
                case 2: blocksStep
                default: paceStep
                }
            }
            .frame(maxWidth: .infinity)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .id(step)

            Spacer(minLength: 24)

            pageDots
                .padding(.bottom, 28)

            Button {
                advance()
            } label: {
                Text(step == stepCount - 1 ? "Start weaving" : "Continue")
                    .primaryButtonStyle()
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 8)

            if step > 0 {
                Button("Back") {
                    withAnimation(.easeInOut(duration: 0.25)) { step -= 1 }
                }
                .font(AppFont.caption(14))
                .foregroundStyle(Color.loomSubtle)
                .padding(.bottom, 12)
            } else {
                Color.clear.frame(height: 30)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hearthScreen()
        .interactiveDismissDisabled()
    }

    private func advance() {
        if step < stepCount - 1 {
            withAnimation(.easeInOut(duration: 0.25)) { step += 1 }
        } else {
            settings.hasCompletedOnboarding = true
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            stepBadge(icon: "square.and.pencil")
            Text("Capture in seconds")
                .font(AppFont.title(24))
                .foregroundStyle(LinearGradient.hearthTitle)
                .padding(.bottom, 10)
            Text("Add a task with a deadline and a rough effort estimate. Loom plans the work for you.")
                .font(AppFont.body(15))
                .foregroundStyle(Color.loomSubtle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - Step 2: Your day

    private var dayStep: some View {
        VStack(spacing: 0) {
            stepBadge(icon: "sunrise.fill")
            Text("Your day")
                .font(AppFont.title(24))
                .foregroundStyle(LinearGradient.hearthTitle)
                .padding(.bottom, 10)
            Text("Loom only schedules work while you're awake. A sleep time past midnight is fine.")
                .font(AppFont.body(15))
                .foregroundStyle(Color.loomSubtle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.bottom, 24)

            VStack(spacing: 0) {
                settingRow(label: "Wake time", icon: "sunrise.fill", iconColor: .workColor) {
                    DatePicker("", selection: timeBinding(
                        hour: { settings.wakeHour }, setHour: { settings.wakeHour = $0 },
                        minute: { settings.wakeMinute }, setMinute: { settings.wakeMinute = $0 }
                    ), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                }
                Divider().overlay(Color.loomBorder).padding(.leading, 16)
                settingRow(label: "Sleep time", icon: "moon.fill", iconColor: .schoolColor) {
                    DatePicker("", selection: timeBinding(
                        hour: { settings.sleepHour }, setHour: { settings.sleepHour = $0 },
                        minute: { settings.sleepMinute }, setMinute: { settings.sleepMinute = $0 }
                    ), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                }
            }
            .background(Color.loomSurface)
            .clipShape(RoundedRectangle(cornerRadius: LoomRadius.card, style: .continuous))
            .padding(.horizontal, 32)
        }
    }

    // MARK: - Step 3: Work blocks

    private var blocksStep: some View {
        VStack(spacing: 0) {
            stepBadge(icon: "calendar.badge.clock")
            Text("Manageable blocks")
                .font(AppFont.title(24))
                .foregroundStyle(LinearGradient.hearthTitle)
                .padding(.bottom, 10)
            Text("Big tasks get split into blocks this size, finishing a safe buffer before the deadline.")
                .font(AppFont.body(15))
                .foregroundStyle(Color.loomSubtle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.bottom, 24)

            VStack(spacing: 0) {
                stepperRow(
                    label: "Minimum block",
                    value: { settings.minBlockMinutes },
                    set: { settings.minBlockMinutes = $0 },
                    range: 15...60, step: 15
                )
                Divider().overlay(Color.loomBorder).padding(.leading, 16)
                stepperRow(
                    label: "Maximum block",
                    value: { settings.maxBlockMinutes },
                    set: { settings.maxBlockMinutes = $0 },
                    range: 60...180, step: 30
                )
                Divider().overlay(Color.loomBorder).padding(.leading, 16)
                stepperRow(
                    label: "Deadline buffer",
                    value: { settings.deadlineBufferMinutes },
                    set: { settings.deadlineBufferMinutes = $0 },
                    range: 0...480, step: 30
                )
            }
            .background(Color.loomSurface)
            .clipShape(RoundedRectangle(cornerRadius: LoomRadius.card, style: .continuous))
            .padding(.horizontal, 32)
        }
    }

    // MARK: - Step 4: Stay on pace

    private var paceStep: some View {
        VStack(spacing: 0) {
            stepBadge(icon: "checkmark")
            Text("Stay on pace")
                .font(AppFont.title(24))
                .foregroundStyle(LinearGradient.hearthTitle)
                .padding(.bottom, 10)
            Text("Miss a block? Loom replans it automatically. Everything you just set can be changed later in Settings.")
                .font(AppFont.body(15))
                .foregroundStyle(Color.loomSubtle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - Pieces

    private func stepBadge(icon: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.brand100)
                .frame(width: 76, height: 76)
            Image(systemName: icon)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Color.brand600)
        }
        .padding(.bottom, 24)
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<stepCount, id: \.self) { index in
                Capsule()
                    .fill(index == step ? Color.brand500 : Color.loomSurface3)
                    .frame(width: index == step ? 18 : 6, height: 6)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: step)
    }

    private func settingRow<Content: View>(
        label: String,
        icon: String,
        iconColor: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Label(label, systemImage: icon)
                .font(AppFont.body(15))
                .foregroundStyle(iconColor)
            Spacer()
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func stepperRow(
        label: String,
        value: @escaping () -> Int,
        set: @escaping (Int) -> Void,
        range: ClosedRange<Int>,
        step stride: Int
    ) -> some View {
        Stepper(value: Binding(get: value, set: set), in: range, step: stride) {
            HStack {
                Text(label)
                    .font(AppFont.body(15))
                    .foregroundStyle(Color.loomText)
                Spacer()
                Text(CountdownFormatter.effortString(minutes: value()))
                    .font(AppFont.mono(14))
                    .foregroundStyle(Color.loomSubtle)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func timeBinding(
        hour: @escaping () -> Int, setHour: @escaping (Int) -> Void,
        minute: @escaping () -> Int, setMinute: @escaping (Int) -> Void
    ) -> Binding<Date> {
        Binding<Date>(
            get: {
                var components = DateComponents()
                components.hour = hour()
                components.minute = minute()
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { newDate in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                setHour(comps.hour ?? 8)
                setMinute(comps.minute ?? 0)
            }
        )
    }
}
