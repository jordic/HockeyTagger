import SwiftData
import Foundation

@Model
final class Project {
    var id: UUID
    var videoBookmark: Data
    var videoName: String
    var lastOpened: Date
    
    @Relationship(deleteRule: .cascade) var clips: [Clip] = []
    
    init(videoBookmark: Data, videoName: String) {
        self.id = UUID()
        self.videoBookmark = videoBookmark
        self.videoName = videoName
        self.lastOpened = Date()
    }
}

@Model
final class Clip {
    var id: UUID
    var label: String
    var startTime: Double
    var endTime: Double
    
    var project: Project?
    
    init(label: String, startTime: Double, endTime: Double) {
        self.id = UUID()
        self.label = label
        self.startTime = startTime
        self.endTime = endTime
    }
}

// DTO for JSON Import/Export
struct ClipDTO: Codable {
    let label: String
    let startTime: Double
    let endTime: Double
}
