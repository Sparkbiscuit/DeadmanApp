//
//  NewTaskView.swift
//  Deadman
//
//  Created by Nicholas Christoforakis on 8/16/24.
//

import SwiftUI

struct NewTaskView: View {
    @Environment(\.presentationMode) var presentationMode
    @ObservedObject var viewModel: TaskViewModel
    
    @State private var taskName: String = ""
    @State private var taskDeadline: Date = Date()
    
    var body: some View {
        NavigationView {
            Form {
                TextField("Task Name", text: $taskName)
                
                DatePicker("Deadline", selection: $taskDeadline, displayedComponents: [.date, .hourAndMinute])
                
                Button("Save Task") {
                    viewModel.addTask(name: taskName, deadline: taskDeadline)
                    presentationMode.wrappedValue.dismiss()
                }
            }
            .navigationTitle("New Task")
            .navigationBarItems(trailing: Button("Cancel") {
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}
