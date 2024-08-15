//
//  EditItemView.swift
//  Deadman
//
//  Created by Nicholas Christoforakis on 8/14/24.
//

import SwiftUI
import SwiftData

struct EditItemView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Bindable var item: Item

    var body: some View {
        Form {
            TextField("Title", text: $item.title)
            DatePicker("Deadline", selection: $item.deadline, displayedComponents: .date)
            
            Button("Save") {
                try? modelContext.save() // Save changes to the context
                dismiss()
            }
        }
        .navigationTitle("Edit Item")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
        }
    }
}
