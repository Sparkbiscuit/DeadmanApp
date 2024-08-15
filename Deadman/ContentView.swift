//
//  ContentView.swift
//  Deadman
//
//  Created by Nicholas Christoforakis on 8/14/24.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [Item]
    
    @State private var selectedItem: Item
    @State private var isPresentingAddItemView = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedItem) {
                ForEach(items) { item in
                    NavigationLink(value: item) {
                        VStack(alignment: .leading) {
                            Text(item.title)
                            Text(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))
                                .font(.subheadline)
                                .foregroundColor(.gray)
                            ProgressView(value: item.progress)
                                .progressViewStyle(LinearProgressViewStyle())
                        }
                    }
                }
                .onDelete(perform: deleteItems)
            }
            .navigationTitle("Items")
            .toolbar {
                ToolbarItem(placement: .automatic) { 
                    Button(action: {
                        isPresentingAddItemView = true
                    }) {
                        Image(systemName: "plus")
                    }
                }
            }
        } detail: {
            if let item = selectedItem {
                EditItemView(item: $selectedItem)
            } else {
                Text("Select an item")
            }
        }
        .sheet(isPresented: $isPresentingAddItemView) {
            AddItemView()
        }
    }

    private func deleteItems(offsets: IndexSet) {
        for offset in offsets {
            let item = items[offset]
            modelContext.delete(item)
        }
        try? modelContext.save()
    }
}
