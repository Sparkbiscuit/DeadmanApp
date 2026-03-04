import SwiftUI

// MARK: - Color Palette

extension Color {
    // Context colors
    static let schoolColor = Color(red: 0.35, green: 0.47, blue: 0.95)     // Soft indigo-blue
    static let workColor = Color(red: 0.95, green: 0.55, blue: 0.25)       // Warm amber
    static let personalColor = Color(red: 0.40, green: 0.78, blue: 0.58)   // Sage green

    // Semantic
    static let deadmanRed = Color(red: 0.92, green: 0.26, blue: 0.28)      // Urgent / brand
    static let deadmanDark = Color(red: 0.09, green: 0.09, blue: 0.11)     // Background dark
    static let deadmanCard = Color(red: 0.13, green: 0.13, blue: 0.15)     // Card surface
    static let deadmanCardLight = Color(red: 0.96, green: 0.96, blue: 0.97) // Card surface light
    static let deadmanSubtle = Color(red: 0.55, green: 0.55, blue: 0.58)   // Muted text
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
            .background(colorScheme == .dark ? Color.deadmanCard : Color.deadmanCardLight)
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
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return "Due \(formatter.string(from: deadline))"
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
