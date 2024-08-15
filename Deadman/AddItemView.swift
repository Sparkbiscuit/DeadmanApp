//
//  AddItemView.swift
//  Deadman
//
//  Created by Nicholas Christoforakis on 8/14/24.
//

import SwiftUI
import SwiftData

struct AddItemView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var deadline = Date()

    var body: some View {
        NavigationView {
            Form {
                TextField("Title", text: $title)
                DatePicker("Deadline", selection: $deadline, displayedComponents: .date)
                
                Button("Add Item") {
                    let newItem = Item(title: title, deadline: deadline)
                    modelContext.insert(newItem) // Insert the new item into the Core Data context
                    try? modelContext.save() // Save the context
                    dismiss()
                }
            }
            .navigationTitle("Add New Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}
