import Foundation
import SwiftData

@Model
final class ImportedWorkout {
    @Attribute(.unique) var id: UUID
    var startDate: Date
    var tileData: Data
    var routeIDs: [UUID] = []

    init(id: UUID, startDate: Date, tiles: Set<GridTile>) throws {
        self.id = id
        self.startDate = startDate
        self.tileData = try JSONEncoder().encode(Array(tiles))
    }

    func tiles() throws -> Set<GridTile> {
        Set(try JSONDecoder().decode([GridTile].self, from: tileData))
    }
}
