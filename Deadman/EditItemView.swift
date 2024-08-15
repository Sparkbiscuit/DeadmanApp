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

    @Binding var item: Item
    @State private var isModified = false

    var body: some View {
        Form {
            TextField("Title", text: $item.title)
            DatePicker("Deadline", selection: $item.deadline, displayedComponents: .date)
        }
        .navigationTitle("Edit Item")
        .onChange(of: item.title) { _ in
            isModified = true
        }
        .onChange(of: item.deadline) { _ in
            isModified = true
        }
        .onDisappear {
            if isModified {
                saveChanges()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") {
                    saveChanges()
                }
            }
        }
    }

    private func saveChanges() {
        do {
            try modelContext.save()
            dismiss() 
        } catch {
            // Handle the error (e.g., show an alert to the user)
            print("Error saving item: \(error.localizedDescription)")
        }
    }
}
