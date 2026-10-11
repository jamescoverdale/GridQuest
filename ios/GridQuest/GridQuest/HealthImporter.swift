import Foundation
import HealthKit
import CoreLocation

nonisolated struct RouteSample: Sendable {
    let point: GridPoint
    let timestamp: Date
    let valid: Bool
}

nonisolated enum HealthImportError: LocalizedError {
    case unavailable
    case authorizationIncomplete
    case routeNotReady
    var errorDescription: String? {
        switch self {
        case .unavailable: "Apple Health is unavailable on this device."
        case .authorizationIncomplete: "Health access could not be requested. Please try again."
        case .routeNotReady: "A workout route is still arriving from Apple Health. GridQuest will retry it on the next sync."
        }
    }
}

actor HealthImporter: HealthDataSource {
    private let store = HKHealthStore()
    private var changedRoutes: [UUID: HKWorkoutRoute] = [:]
    private var observer: HKObserverQuery?

    func authorize() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthImportError.unavailable }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: [], read: [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]) { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: HealthImportError.authorizationIncomplete) }
            }
        }
    }

    func changes(after anchorData: Data?) async throws -> HealthRouteBatch {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthImportError.unavailable }
        let anchor = try anchorData.flatMap { try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
        let (routes, nextAnchor): ([HKWorkoutRoute], HKQueryAnchor) = try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(type: HKSeriesType.workoutRoute(), predicate: nil,
                                             anchor: anchor, limit: HKObjectQueryNoLimit) { _, added, _, newAnchor, error in
                if let error { continuation.resume(throwing: error) }
                else if let newAnchor { continuation.resume(returning: (added as? [HKWorkoutRoute] ?? [], newAnchor)) }
                else { continuation.resume(throwing: HealthImportError.routeNotReady) }
            }
            store.execute(query)
        }
        changedRoutes = Dictionary(uniqueKeysWithValues: routes.map { ($0.uuid, $0) })
        return HealthRouteBatch(routeIDs: routes.map(\.uuid),
                                nextAnchor: try NSKeyedArchiver.archivedData(withRootObject: nextAnchor, requiringSecureCoding: true))
    }

    func importRoute(id: UUID) async throws -> ImportedRoute? {
        let route: HKWorkoutRoute
        if let cached = changedRoutes[id] { route = cached }
        else {
            let matches = try await samples(type: HKSeriesType.workoutRoute(), predicate: HKQuery.predicateForObject(with: id))
            guard let saved = matches.first as? HKWorkoutRoute else { throw HealthImportError.routeNotReady }
            route = saved
        }
        // HealthKit exposes workout -> route association, not its inverse. Limit
        // the workout lookup to the changed route's interval and verify association.
        let interval = HKQuery.predicateForSamples(withStart: route.startDate.addingTimeInterval(-1),
                                                   end: route.endDate.addingTimeInterval(1))
        let candidates = try await samples(type: HKObjectType.workoutType(), predicate: interval)
        for workout in candidates.compactMap({ $0 as? HKWorkout }) {
            let association = NSCompoundPredicate(andPredicateWithSubpredicates: [
                HKQuery.predicateForObjects(from: workout), HKQuery.predicateForObject(with: id)
            ])
            let matching = try await samples(type: HKSeriesType.workoutRoute(), predicate: association)
            guard !matching.isEmpty else { continue }
            if (workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool) == true { return nil }
            let locations = try await routeSamples(route)
            // Do not checkpoint a route whose geographic samples are not ready yet.
            guard !locations.isEmpty else { throw HealthImportError.routeNotReady }
            return ImportedRoute(workoutID: workout.uuid, workoutDate: workout.startDate,
                                 tiles: Self.tiles(from: locations))
        }
        throw HealthImportError.routeNotReady
    }

    func observeChanges(_ onChange: @escaping @Sendable () async -> Void) {
        guard observer == nil else { return }
        let query = HKObserverQuery(sampleType: HKSeriesType.workoutRoute(), predicate: nil) { _, completion, error in
            guard error == nil else { completion(); return }
            Task { await onChange(); completion() }
        }
        observer = query
        store.execute(query)
    }

    func stopObserving() {
        if let observer { store.stop(observer) }
        observer = nil
    }

    /// Keep separate HealthKit routes separate. Invalid points and long recording
    /// gaps break a segment instead of awarding a straight line across missing GPS.
    nonisolated static func tiles(from samples: [RouteSample]) -> Set<GridTile> {
        var result = Set<GridTile>()
        var segment: [GridPoint] = []
        var previousDate: Date?
        for sample in samples {
            let gap = previousDate.map { sample.timestamp.timeIntervalSince($0) } ?? 0
            if !sample.valid || gap > 300 || gap < 0 {
                result.formUnion(TileCalculator.tiles(along: segment))
                segment.removeAll(keepingCapacity: true)
            }
            if sample.valid { segment.append(sample.point) }
            previousDate = sample.timestamp
        }
        result.formUnion(TileCalculator.tiles(along: segment))
        return result
    }

    private func samples(type: HKSampleType, predicate: NSPredicate?) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples ?? []) }
            }
            store.execute(query)
        }
    }

    private func routeSamples(_ route: HKWorkoutRoute) async throws -> [RouteSample] {
        try await withCheckedThrowingContinuation { continuation in
            let accumulator = RouteAccumulator()
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                let outcome = accumulator.append(locations ?? [], done: done, error: error)
                if let outcome { continuation.resume(with: outcome) }
            }
            store.execute(query)
        }
    }
}

/// HealthKit returns route data in batches. Guard the continuation against
/// duplicate completion and keep callback state independent of actor isolation.
nonisolated private final class RouteAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [RouteSample] = []
    private var finished = false

    func append(_ locations: [CLLocation], done: Bool, error: Error?) -> Result<[RouteSample], Error>? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        if let error { finished = true; return .failure(error) }
        values.append(contentsOf: locations.map {
            RouteSample(point: GridPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude),
                        timestamp: $0.timestamp, valid: $0.horizontalAccuracy >= 0 && CLLocationCoordinate2DIsValid($0.coordinate))
        })
        if done { finished = true; return .success(values) }
        return nil
    }
}
