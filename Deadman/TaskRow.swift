//
//  TaskRow.swift
//  Deadman
//
//  Created by Nicholas Christoforakis on 8/15/24.
//

import SwiftUI

struct TaskRow: View {
    var task: Task
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(task.name ?? "Unnamed Task")
                .font(.headline)
            Text(formatDeadline(task.deadline))
                .font(.subheadline)
                .foregroundColor(.gray)
            ProgressView(value: calculateProgress(task: task))
        }
    }
    
    // Formats the deadline to include both date and time
    private func formatDeadline(_ deadline: Date?) -> String {
        guard let deadline = deadline else { return "No deadline" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short // Includes the time
        return formatter.string(from: deadline)
    }
    
    // Calculates the progress between creation and deadline
    private func calculateProgress(task: Task) -> Double {
        guard let creationDate = task.creationDate, let deadline = task.deadline else {
            return 0.0
        }
        let totalTime = deadline.timeIntervalSince(creationDate)
        let elapsedTime = Date().timeIntervalSince(creationDate)
        return min(max(elapsedTime / totalTime, 0.0), 1.0)
    }
}
