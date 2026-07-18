import Foundation
import SwiftData

/// Everything Filuma knows, as portable JSON. A trust feature: the plan, the
/// history, and the settings are the user's — exportable any time, readable
/// by anything. Also doubles as a manual backup.
enum DataExporter {

    struct Export: Codable {
        var version = 2
        var exportedAt = Date()
        var tasks: [TaskRecord] = []
        var templates: [TemplateRecord] = []
        var blocks: [BlockRecord] = []
        var workSessions: [SessionRecord] = []
        var reminders: [ReminderRecord] = []
        var blockedTimes: [BlockedTimeRecord] = []
    }

    struct TaskRecord: Codable {
        let id: UUID
        let title: String
        let context: String
        let deadline: Date
        let effortMinutes: Int
        let isComplete: Bool
        let completedAt: Date?
        let manualProgressPercent: Int
        let firstStep: String?
        let source: String
        let templateId: UUID?
    }

    struct TemplateRecord: Codable {
        let id: UUID
        let title: String
        let context: String
        let effortMinutes: Int
        let firstStep: String?
        let nextDeadline: Date
        let repeatUntil: Date
    }

    struct BlockRecord: Codable {
        let id: UUID
        let taskId: UUID?
        let startTime: Date
        let durationMinutes: Int
        let isComplete: Bool
        let isLocked: Bool
    }

    struct SessionRecord: Codable {
        let id: UUID
        let taskId: UUID?
        let scheduledBlockId: UUID?
        let startedAt: Date
        let durationSeconds: Int
    }

    struct ReminderRecord: Codable {
        let id: UUID
        let title: String
        let dueDate: Date
        let isComplete: Bool
    }

    struct BlockedTimeRecord: Codable {
        let id: UUID
        let label: String
        let weekdays: [Int]
        let startHour: Int
        let startMinute: Int
        let durationMinutes: Int
    }

    static func exportJSON(context: ModelContext) throws -> Data {
        var export = Export()

        export.tasks = try context.fetch(FetchDescriptor<FilumaTask>()).map { task in
            TaskRecord(
                id: task.id,
                title: task.title,
                context: task.context.rawValue,
                deadline: task.deadline,
                effortMinutes: task.effortMinutes,
                isComplete: task.isComplete,
                completedAt: task.completedAt,
                manualProgressPercent: task.manualProgressPercent,
                firstStep: task.firstStep,
                source: task.source.rawValue,
                templateId: task.templateId
            )
        }
        export.templates = try context.fetch(FetchDescriptor<TaskTemplate>()).map { template in
            TemplateRecord(
                id: template.id,
                title: template.title,
                context: template.context.rawValue,
                effortMinutes: template.effortMinutes,
                firstStep: template.firstStep,
                nextDeadline: template.nextDeadline,
                repeatUntil: template.repeatUntil
            )
        }
        export.blocks = try context.fetch(FetchDescriptor<ScheduledBlock>()).map { block in
            BlockRecord(
                id: block.id,
                taskId: block.task?.id,
                startTime: block.startTime,
                durationMinutes: block.durationMinutes,
                isComplete: block.isComplete,
                isLocked: block.isLocked
            )
        }
        export.workSessions = try context.fetch(FetchDescriptor<WorkSession>()).map { session in
            SessionRecord(
                id: session.id,
                taskId: session.task?.id,
                scheduledBlockId: session.scheduledBlockId,
                startedAt: session.startedAt,
                durationSeconds: session.durationSeconds
            )
        }
        export.reminders = try context.fetch(FetchDescriptor<Reminder>()).map { reminder in
            ReminderRecord(
                id: reminder.id,
                title: reminder.title,
                dueDate: reminder.dueDate,
                isComplete: reminder.isComplete
            )
        }
        export.blockedTimes = try context.fetch(FetchDescriptor<BlockedTime>()).map { blocked in
            BlockedTimeRecord(
                id: blocked.id,
                label: blocked.label,
                weekdays: blocked.weekdays,
                startHour: blocked.startHour,
                startMinute: blocked.startMinute,
                durationMinutes: blocked.durationMinutes
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(export)
    }

    /// Write the export to a shareable temp file, named by date.
    static func writeExportFile(context: ModelContext) throws -> URL {
        let data = try exportJSON(context: context)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Filuma Export \(formatter.string(from: Date())).json")
        try data.write(to: url, options: .atomic)
        return url
    }
}
