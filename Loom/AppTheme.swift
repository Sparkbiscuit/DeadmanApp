import SwiftUI

// MARK: - Hex helpers

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// A color that resolves differently in light and dark mode.
    init(lightHex: UInt32, darkHex: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? darkHex : lightHex
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

// MARK: - Color Palette (design-handoff tokens)

extension Color {
    // Brand — Ember
    static let brand100 = Color(hex: 0xFBE4D4)
    static let brand300 = Color(hex: 0xEFA36C)
    static let brand500 = Color(hex: 0xC1571F)
    static let brand600 = Color(hex: 0xA64715)
    static let brand700 = Color(hex: 0x8A3A10)

    // Semantic — urgency & task contexts
    static let loomRed = Color(hex: 0xE2434A)
    static let loomRedPressed = Color(hex: 0xC93039)
    static let schoolColor = Color(hex: 0x5A78E0)
    static let workColor = Color(hex: 0xE0A020)
    static let personalColor = Color(hex: 0x3FA372)

    // Surfaces (adaptive: light / dark)
    static let loomBackground = Color(lightHex: 0xF4F4F6, darkHex: 0x121214)
    static let loomSurface = Color(lightHex: 0xFFFFFF, darkHex: 0x1C1C1F)
    static let loomSurface2 = Color(lightHex: 0xEAEAEF, darkHex: 0x29292D)
    static let loomSurface3 = Color(lightHex: 0xDEDEE3, darkHex: 0x333338)
    static let loomText = Color(lightHex: 0x1C1C1E, darkHex: 0xF5F5F7)
    static let loomSubtle = Color(lightHex: 0x6E6E76, darkHex: 0x9A9AA2)
    static let loomFaint = Color(lightHex: 0x9A9AA2, darkHex: 0x6E6E76)

    static let loomBorder = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.08)
            : UIColor(white: 0, alpha: 0.07)
    })
}

extension TaskContext {
    var color: Color {
        switch self {
        case .school: return .schoolColor
        case .work: return .workColor
        case .personal: return .personalColor
        }
    }
}

// MARK: - Corner radii

enum LoomRadius {
    static let sm: CGFloat = 8
    static let button: CGFloat = 14
    static let card: CGFloat = 16
    static let sheet: CGFloat = 24
}

// MARK: - Typography (Nunito + JetBrains Mono)

struct AppFont {
    /// Display — Nunito ExtraBold
    static func display(_ size: CGFloat = 34) -> Font {
        .custom("Nunito-ExtraBold", size: size, relativeTo: .largeTitle)
    }

    /// Screen titles ("Your Tasks") use the heaviest cut.
    static func title(_ size: CGFloat = 26) -> Font {
        .custom("Nunito-Black", size: size, relativeTo: .title)
    }

    /// Heading — Nunito Bold
    static func heading(_ size: CGFloat = 20) -> Font {
        .custom("Nunito-Bold", size: size, relativeTo: .headline)
    }

    /// Body — Nunito Regular
    static func body(_ size: CGFloat = 16) -> Font {
        .custom("Nunito-Regular", size: size, relativeTo: .body)
    }

    /// Emphasized body — Nunito SemiBold
    static func bodySemibold(_ size: CGFloat = 16) -> Font {
        .custom("Nunito-SemiBold", size: size, relativeTo: .body)
    }

    /// Caption — Nunito Bold
    static func caption(_ size: CGFloat = 13) -> Font {
        .custom("Nunito-Bold", size: size, relativeTo: .caption)
    }

    /// Numeric/time displays — JetBrains Mono SemiBold
    static func mono(_ size: CGFloat = 14) -> Font {
        .custom("JetBrainsMono-SemiBold", size: size, relativeTo: .body)
    }

    static func monoMedium(_ size: CGFloat = 14) -> Font {
        .custom("JetBrainsMono-Medium", size: size, relativeTo: .body)
    }
}

// MARK: - View Modifiers

struct CardModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Color.loomSurface)
            .clipShape(RoundedRectangle(cornerRadius: LoomRadius.card, style: .continuous))
            // Elevation is light-mode only; dark mode relies on surface contrast.
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.06), radius: 1, y: 1)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.05), radius: 10, y: 8)
    }
}

struct ContextTagModifier: ViewModifier {
    let context: TaskContext

    func body(content: Content) -> some View {
        content
            .font(AppFont.caption(11))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(context.color, in: Capsule())
    }
}

/// Full-width brand CTA ("Schedule it", "Save Progress"…).
struct PrimaryButtonModifier: ViewModifier {
    var fill: Color = .brand500
    var enabled: Bool = true

    func body(content: Content) -> some View {
        content
            .font(AppFont.heading(16))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: LoomRadius.button, style: .continuous)
                    .fill(enabled ? fill : Color.loomFaint)
            )
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardModifier())
    }

    func contextTag(_ context: TaskContext) -> some View {
        modifier(ContextTagModifier(context: context))
    }

    func primaryButtonStyle(fill: Color = .brand500, enabled: Bool = true) -> some View {
        modifier(PrimaryButtonModifier(fill: fill, enabled: enabled))
    }
}

// MARK: - Shared components

/// Icon-in-circle + heading + subtext (+ optional ghost CTA) empty-state pattern.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color.loomSurface2)
                    .frame(width: 52, height: 52)
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Color.loomFaint)
            }
            .padding(.bottom, 6)

            Text(title)
                .font(AppFont.heading(16))
                .foregroundStyle(Color.loomText)
            Text(subtitle)
                .font(AppFont.body(13))
                .foregroundStyle(Color.loomSubtle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)

            if let actionLabel, let action {
                Button(action: action) {
                    Text(actionLabel)
                        .font(AppFont.caption(13))
                        .foregroundStyle(Color.brand500)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .overlay(Capsule().stroke(Color.loomBorder, lineWidth: 1))
                }
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }
}

/// Inline info banner (e.g. "Replanned 2 missed blocks").
struct InfoBanner: View {
    let icon: String
    let text: String
    var tint: Color = .schoolColor

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(AppFont.body(13))
                .foregroundStyle(Color.loomText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.loomSurface)
        .clipShape(RoundedRectangle(cornerRadius: LoomRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LoomRadius.card, style: .continuous)
                .stroke(Color.loomBorder, lineWidth: 1)
        )
    }
}

// MARK: - Countdown Formatting

struct CountdownFormatter {
    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    static func string(from now: Date, to target: Date) -> String {
        let interval = target.timeIntervalSince(now)
        if interval < 0 {
            return "overdue"
        }

        let minutes = Int(interval) / 60
        let hours = minutes / 60
        let days = hours / 24

        if days > 0 {
            return days == 1 ? "in 1 day" : "in \(days) days"
        } else if hours > 0 {
            return hours == 1 ? "in 1 hour" : "in \(hours) hours"
        } else if minutes > 0 {
            return minutes == 1 ? "in 1 min" : "in \(minutes) min"
        } else {
            return "now"
        }
    }

    static func deadlineString(from now: Date, to deadline: Date) -> String {
        let interval = deadline.timeIntervalSince(now)
        if interval < 0 {
            return "Past due"
        }

        let hours = Int(interval) / 3600
        let days = hours / 24

        if days > 7 {
            return "Due \(monthDayFormatter.string(from: deadline))"
        } else if days > 0 {
            return days == 1 ? "Due tomorrow" : "Due in \(days) days"
        } else if hours > 0 {
            return hours == 1 ? "Due in 1 hour" : "Due in \(hours) hours"
        } else {
            return "Due very soon"
        }
    }

    static func effortString(minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes)m"
        } else {
            let h = minutes / 60
            let m = minutes % 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
    }

    static func timerString(seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Time formatting

struct TimeFormatter {
    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    static let dayOfWeek: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()
}
