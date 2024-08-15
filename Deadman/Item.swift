//
//  Item.swift
//  Deadman
//
//  Created by Nicholas Christoforakis on 8/14/24.
//
import SwiftData
import Foundation

@Model
class Item: Identifiable {
    @Attribute(.unique) var id: UUID
    @Attribute var title: String
    @Attribute var timestamp: Date
    @Attribute var deadline: Date
    
    var progress: Double {
        let totalTime = deadline.timeIntervalSince(timestamp)
        let elapsedTime = Date().timeIntervalSince(timestamp)
        return min(max(elapsedTime / totalTime, 0.0), 1.0)
    }

    init(id: UUID = UUID(), title: String, timestamp: Date = Date(), deadline: Date) {
        self.id = id
        self.title = title
        self.timestamp = timestamp
        self.deadline = deadline
    }
}
