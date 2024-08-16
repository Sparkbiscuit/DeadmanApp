//
//  EditTaskView.swift
//  Deadman
//
//  Created by Nicholas Christoforakis on 8/16/24.
//

import SwiftUI

struct EditTaskView: View {
    @Environment(\.presentationMode) var presentationMode
    @ObservedObject var viewModel: TaskViewModel
    @State private var task: Task
    @State private var taskName: String
    @State private var taskDeadline: Date

    init(viewModel: TaskViewModel, task: Task) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _task = State(initialValue: task)
        _taskName = State(initialValue: task.name ?? "")
        _taskDeadline = State(initialValue: task.deadline ?? Date())
    }

    var body: some View {
        NavigationView {
            Form {
                TextField("Task Name", text: $taskName)
                
                DatePicker("Deadline", selection: $taskDeadline, displayedComponents: [.date, .hourAndMinute])
                
                Button("Save Changes") {
                    task.name = taskName
                    task.deadline = taskDeadline
                    viewModel.saveContext()
                    presentationMode.wrappedValue.dismiss()
                }
            }
            .navigationTitle("Edit Task")
            .navigationBarItems(trailing: Button("Cancel") {
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}
