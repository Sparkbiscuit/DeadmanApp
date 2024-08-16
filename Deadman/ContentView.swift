//
//  ContentView.swift
//  Deadman
//
//  Created by Nicholas Christoforakis on 8/14/24.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject var viewModel: TaskViewModel
    @State private var showingNewTaskView = false
    
    init() {
        _viewModel = StateObject(wrappedValue: TaskViewModel(context: PersistenceController.shared.container.viewContext))
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                // Title and Logo
                HStack {
                    Text("Deadman")
                        .font(.largeTitle)
                        .bold()
                    Spacer()
                    Image(systemName: "square.fill")
                        .resizable()
                        .frame(width: 40, height: 40)
                        .cornerRadius(8)
                }
                .padding(.horizontal)
                
                // Current Date
                Text(todayFormatted())
                    .font(.headline)
                    .padding(.horizontal)
                
                // Task List
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(viewModel.tasks) { task in
                            NavigationLink(destination: EditTaskView(viewModel: viewModel, task: task)) {
                                TaskRow(task: task)
                                    .padding(.horizontal)
                            }
                        }
                    }
                }
                
                Spacer()
                
                // New Task Button
                Button(action: {
                    showingNewTaskView = true
                }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.red)
                        Text("New Task")
                            .font(.headline)
                            .foregroundColor(.red)
                    }
                }
                .padding()
            }
            .padding(.top)
            .sheet(isPresented: $showingNewTaskView) {
                NewTaskView(viewModel: viewModel)
            }
        }
    }
    
    func todayFormatted() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        return formatter.string(from: Date())
    }
}
