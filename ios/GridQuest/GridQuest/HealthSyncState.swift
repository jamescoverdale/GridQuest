import Foundation
import SwiftData

@Model
final class HealthSyncState {
    @Attribute(.unique) var key: String = "health"
    var isConnected: Bool = false
    var routeAnchor: Data?
    var lastSync: Date?
    // Indoor routes can be acknowledged without contributing to the grid.
    var ignoredRouteIDs: [UUID] = []
    var pendingRouteIDs: [UUID] = []
    var pendingRetryAfter: Date?

    init() {}
}

nonisolated struct HealthRouteBatch: Sendable {
    let routeIDs: [UUID]
    let nextAnchor: Data
}

nonisolated struct ImportedRoute: Sendable {
    let workoutID: UUID
    let workoutDate: Date
    let tiles: Set<GridTile>
}

nonisolated protocol HealthDataSource: Sendable {
    func authorize() async throws
    func changes(after anchor: Data?) async throws -> HealthRouteBatch
    func importRoute(id: UUID) async throws -> ImportedRoute?
    func observeChanges(_ onChange: @escaping @Sendable () async -> Void) async
    func stopObserving() async
}
