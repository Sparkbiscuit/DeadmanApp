import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Color Palette

extension Color {
    // Context colors
    static let schoolColor = Color(red: 0.35, green: 0.47, blue: 0.95)     // Soft indigo-blue
    static let workColor = Color(red: 0.85, green: 0.50, blue: 0.20)       // Warm amber (contrast-safe)
    static let personalColor = Color(red: 0.25, green: 0.65, blue: 0.45)   // Sage green (contrast-safe)

    // Semantic
    static let loomRed = Color(red: 0.92, green: 0.26, blue: 0.28)      // Urgent / brand
    static let loomDark = Color(red: 0.09, green: 0.09, blue: 0.11)     // Background dark
    static let loomCard = Color(red: 0.13, green: 0.13, blue: 0.15)     // Card surface
    static let loomCardLight = Color(red: 0.96, green: 0.96, blue: 0.97) // Card surface light
    static let loomSubtle = Color(red: 0.44, green: 0.44, blue: 0.47)   // Muted text (WCAG AA compliant)
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

// MARK: - Haptics

struct Haptics {
    #if os(iOS)
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
    #else
    static func impact(_ style: Any? = nil) {}
    static func selection() {}
    static func notification(_ type: Any? = nil) {}
    #endif
}

// MARK: - Cached Formatters

enum SharedFormatters {
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    static let sessionFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()
}

// MARK: - Typography

struct AppFont {
    static func title(_ size: CGFloat = 28) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }

    static func heading(_ size: CGFloat = 20) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }

    static func body(_ size: CGFloat = 16) -> Font {
        .system(size: size, weight: .regular, design: .rounded)
    }

    static func caption(_ size: CGFloat = 13) -> Font {
        .system(size: size, weight: .medium, design: .rounded)
    }

    static func mono(_ size: CGFloat = 14) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }
}

// MARK: - View Modifiers

struct CardModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(colorScheme == .dark ? Color.loomCard : Color.loomCardLight)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct ContextTagModifier: ViewModifier {
    let context: TaskContext

    func body(content: Content) -> some View {
        content
            .font(AppFont.caption(11))
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(context.color, in: Capsule())
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardModifier())
    }

    func contextTag(_ context: TaskContext) -> some View {
        modifier(ContextTagModifier(context: context))
    }
}

// MARK: - Countdown Formatting

struct CountdownFormatter {
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
            return "Due \(SharedFormatters.dateFormatter.string(from: deadline))"
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
}
