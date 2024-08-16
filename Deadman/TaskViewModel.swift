//
//  ViewModel.swift
//  Deadman
//
//  Created by Nicholas Christoforakis on 8/15/24.
//

import SwiftUI
import CoreData

class TaskViewModel: ObservableObject {
    private let viewContext: NSManagedObjectContext
    @Published var tasks: [Task] = []
    
    init(context: NSManagedObjectContext) {
        self.viewContext = context
        fetchTasks()
    }
    
    func fetchTasks() {
        // Manually create the fetch request
        let request: NSFetchRequest<Task> = Task.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Task.creationDate, ascending: true)]
        
        do {
            tasks = try viewContext.fetch(request)
        } catch {
            print("Failed to fetch tasks: \(error)")
        }
    }
    
    func addTask(name: String, deadline: Date) {
        let newTask = Task(context: viewContext)
        newTask.name = name
        newTask.deadline = deadline
        newTask.creationDate = Date()
        
        saveContext()
        fetchTasks()
    }
    
    func saveContext() {
        if viewContext.hasChanges {
            do {
                try viewContext.save()
                fetchTasks() // Refresh tasks after saving
            } catch {
                print("Failed to save context: \(error)")
            }
    func updateTask(_ task: Task, name: String, deadline: Date) {
        task.name = name
        task.deadline = deadline
        saveContext()
        fetchTasks() // Ensure the main view updates with the new deadline
            }
        }
    }
}
