import Foundation
import MapKit
import SwiftData
import SwiftUI
import Testing
@testable import GridQuest

struct GridQuestTests {
    @Test func routeSetsMatch120ExtractedSquadraFixtures() throws {
        struct Fixture: Decodable { let points: [GridPoint]; let expected: [String] }
        let url = try #require(Bundle(for: TestResources.self).url(forResource: "SquadraRouteFixtures", withExtension: "json"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        #expect(fixtures.count == 120)
        for fixture in fixtures {
            #expect(Set(TileCalculator.tiles(along: fixture.points).map(\.id)) == Set(fixture.expected))
        }
    }

    @Test func londonMatchesExtractedSquadraGrid() throws {
        let tile = try #require(GridTile(GridPoint(latitude: 51.5074, longitude: -0.1278)))
        #expect(tile == GridTile(x: 8186, y: 5448))
        #expect(tile.west == -0.1318359375)
        #expect(abs(tile.north - 51.50874245880333) < 1e-10)
    }

    @Test func longitudeWrapsAndInvalidCoordinatesAreRejected() {
        #expect(GridTile(GridPoint(latitude: 0, longitude: 180))?.x == 0)
        #expect(GridTile(GridPoint(latitude: 0, longitude: -180))?.x == 0)
        #expect(GridTile(GridPoint(latitude: 90, longitude: 0)) == nil)
        #expect(GridTile(GridPoint(latitude: .nan, longitude: 0)) == nil)
    }

    @Test func sparseRouteAwardsIntermediateTilesInBothDirections() {
        let a = GridTile(x: 8186, y: 5448).center
        let b = GridTile(x: 8189, y: 5448).center
        let expected = Set((8186...8189).map { GridTile(x: $0, y: 5448) })
        #expect(TileCalculator.tiles(along: [a, b]) == expected)
        #expect(TileCalculator.tiles(along: [b, a]) == expected)
    }

    @Test func repeatedPointsAreDeduplicated() {
        let tile = GridTile(x: 8186, y: 5448)
        #expect(TileCalculator.tiles(along: [tile.center, tile.center, tile.center]) == [tile])
        #expect(TileCalculator.tiles(along: []).isEmpty)
    }

    @Test func largestSquareReportsSideLengthAndKeepsTies() {
        var tiles = Set<GridTile>()
        for start in [100, 1000] {
            for x in start..<(start + 3) { for y in 100..<103 { tiles.insert(GridTile(x: x, y: y)) } }
        }
        let squares = TileCalculator.largestSquares(in: tiles)
        #expect(squares.count == 2)
        #expect(squares.allSatisfy { $0.size == 3 })
        tiles.remove(GridTile(x: 101, y: 101))
        #expect(TileCalculator.largestSquares(in: tiles).count == 1)
        #expect(TileCalculator.largestSquares(in: []).isEmpty)
    }

    @Test func missingGpsDoesNotCollectInterveningSquares() {
        let a = GridTile(x: 8186, y: 5448), b = GridTile(x: 8189, y: 5448)
        let date = Date(timeIntervalSince1970: 0)
        let samples = [RouteSample(point: a.center, timestamp: date, valid: true),
                       RouteSample(point: b.center, timestamp: date.addingTimeInterval(301), valid: true)]
        #expect(HealthImporter.tiles(from: samples) == [a, b])
        let invalid = RouteSample(point: a.center, timestamp: date.addingTimeInterval(1), valid: false)
        #expect(HealthImporter.tiles(from: [samples[0], invalid, RouteSample(point: b.center, timestamp: date.addingTimeInterval(2), valid: true)]) == [a, b])
    }

    @MainActor @Test func savedGridSurvivesNewContextAndDemoDoesNotChangeIt() throws {
        let container = try ModelContainer(for: ImportedWorkout.self, HealthSyncState.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let original: Set<GridTile> = [GridTile(x: 8186, y: 5448)]
        context.insert(try ImportedWorkout(id: UUID(), startDate: Date(), tiles: original))
        try context.save()
        let store = GridStore()
        store.load(from: ModelContext(container))
        #expect(store.tiles == original)
        #expect(store.workoutCount == 1)
        store.showDemo()
        #expect(store.isDemo)
        #expect(store.tiles.count > 1)
        store.closeDemo(context: ModelContext(container))
        #expect(store.tiles == original)
        #expect(!store.isDemo)
    }

    @MainActor @Test func locationFixCentersMapOnUserRatherThanSampleGrid() throws {
        let location = UserLocation()
        location.locationManager(CLLocationManager(), didUpdateLocations: [CLLocation(latitude: 37.7749, longitude: -122.4194)])
        let point = try #require(location.point)
        let view = GridMapView(tiles: [], squares: [], showGrid: false, frameRequest: 0,
                               userLocation: point, cameraRequest: nil, selectedTile: .constant(nil))
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.makeCoordinator().center(map, on: point)
        #expect(abs(map.region.center.latitude - 37.7749) < 0.001)
        #expect(abs(map.region.center.longitude + 122.4194) < 0.001)
        #expect(map.region.span.latitudeDelta < 1)
        #expect(map.accessibilityValue == "Showing current location")
    }

    @MainActor @Test func selectedOverlayMovesSurvivesRefreshAndClears() throws {
        let a = GridTile(x: 8186, y: 5448), b = GridTile(x: 8187, y: 5448)
        func view(_ selection: GridTile?) -> GridMapView {
            GridMapView(tiles: [a], squares: [], showGrid: false, frameRequest: 0,
                        userLocation: nil, cameraRequest: nil, selectedTile: .constant(selection))
        }
        let map = MKMapView()
        let coordinator = view(a).makeCoordinator()
        coordinator.updateSelection(map)
        let overlay = try #require(map.overlays.first as? MKPolygon)
        #expect(overlay.title == "selected")
        #expect(overlay.boundingMapRect.origin.x == GridMapView.polygon(a.corners).boundingMapRect.origin.x)
        #expect(overlay.boundingMapRect.origin.y == GridMapView.polygon(a.corners).boundingMapRect.origin.y)
        #expect(map.accessibilityValue == "Selected collected square")
        let renderer = try #require(coordinator.mapView(map, rendererFor: overlay) as? MKPolygonRenderer)
        #expect(renderer.strokeColor == .systemBlue)
        #expect(renderer.lineWidth == 4)
        // Base overlays may be rebuilt as another route arrives.
        map.removeOverlays(map.overlays)
        coordinator.updateSelection(map)
        #expect(map.overlays.count == 1)
        coordinator.parent = view(b)
        coordinator.updateSelection(map)
        #expect(map.overlays.count == 1)
        #expect(map.overlays.first?.boundingMapRect.origin.x == GridMapView.polygon(b.corners).boundingMapRect.origin.x)
        #expect(map.accessibilityValue == "Selected uncollected square")
        coordinator.parent = view(nil)
        coordinator.updateSelection(map)
        #expect(map.overlays.isEmpty)
    }
}

@MainActor
struct IncrementalSyncTests {
    private func database() throws -> ModelContainer {
        try ModelContainer(for: ImportedWorkout.self, HealthSyncState.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func checkpointSkipsOldGPSButIncludesLateRoutesForOldWorkouts() async throws {
        let container = try database(), context = ModelContext(container)
        let source = FakeHealthSource()
        let first = UUID(), late = UUID(), workout = UUID()
        let a = GridTile(x: 8186, y: 5448), b = GridTile(x: 8187, y: 5448)
        await source.prepare(routes: [first], imports: [first: ImportedRoute(workoutID: workout, workoutDate: .distantPast, tiles: [a])])
        let store = GridStore(importer: source)
        await store.connect(context: context)
        await source.prepare(routes: [late], imports: [late: ImportedRoute(workoutID: workout, workoutDate: .distantPast, tiles: [b])])
        await store.sync(context: context)
        await source.prepare(routes: [], imports: [:])
        await store.sync(context: context)
        #expect(await source.anchors == [nil, Data([1]), Data([2])])
        #expect(await source.importedIDs == [first, late])
        #expect(store.tiles == [a, b])
        #expect(store.workoutCount == 1)
        let restored = GridStore(importer: source)
        restored.load(from: ModelContext(container))
        #expect(restored.isConnected)
        #expect(restored.tiles == [a, b])
        #expect(restored.lastSync != nil)
    }

    @Test func partialFailureRetriesOnlyMissingRouteAfterReload() async throws {
        let container = try database(), context = ModelContext(container)
        let source = FakeHealthSource()
        let good = UUID(), waiting = UUID()
        let a = GridTile(x: 8186, y: 5448), b = GridTile(x: 8187, y: 5448)
        let imports = [good: ImportedRoute(workoutID: UUID(), workoutDate: Date(), tiles: [a]),
                       waiting: ImportedRoute(workoutID: UUID(), workoutDate: Date(), tiles: [b])]
        await source.prepare(routes: [good, waiting], imports: imports, failures: [waiting])
        let store = GridStore(importer: source)
        await store.connect(context: context)
        #expect(store.tiles == [a])
        #expect(store.error != nil)
        #expect(try context.fetch(FetchDescriptor<HealthSyncState>()).first?.routeAnchor == Data([1]))
        #expect(try context.fetch(FetchDescriptor<HealthSyncState>()).first?.pendingRouteIDs == [waiting])
        // A new anchored batch contains neither old route. Pending work survives
        // a fresh store/context and is retried directly by ID.
        await source.prepare(routes: [], imports: imports)
        let restored = GridStore(importer: source)
        let newContext = ModelContext(container)
        restored.load(from: newContext)
        await restored.sync(context: newContext)
        #expect(await source.anchors == [nil, Data([1])])
        #expect(await source.importedIDs == [good, waiting, waiting])
        #expect(restored.tiles == [a, b])
        #expect(restored.error == nil)
        #expect(try newContext.fetch(FetchDescriptor<HealthSyncState>()).first?.routeAnchor == Data([2]))
    }

    @Test func automaticChangesSyncAndIgnoredRoutesAreNotReadAgain() async throws {
        let container = try database(), context = ModelContext(container)
        let source = FakeHealthSource()
        let ignored = UUID(), route = UUID(), tile = GridTile(x: 8186, y: 5448)
        await source.prepare(routes: [ignored], imports: [:])
        let store = GridStore(importer: source)
        await store.connect(context: context)
        await source.prepare(routes: [], imports: [:])
        await store.activate(context: context)
        await source.prepare(routes: [ignored, route], imports: [route: ImportedRoute(workoutID: UUID(), workoutDate: Date(), tiles: [tile])])
        await source.notify()
        #expect(store.tiles == [tile])
        #expect(await source.importedIDs == [ignored, route])
        #expect(await source.anchors == [nil, Data([1]), Data([2])])
        await store.deactivate()
        #expect(await source.isObserving == false)
    }

    @Test func failedFullHistoryCheckKeepsPendingIDsAndAutomaticErrorsStayQuiet() async throws {
        let container = try database(), context = ModelContext(container)
        let source = FakeHealthSource()
        await source.prepare(routes: [], imports: [:])
        let store = GridStore(importer: source)
        await store.connect(context: context)
        let route = UUID()
        await source.prepare(routes: [route], imports: [:], failures: [route])
        await store.sync(context: context, automatic: true, fullHistory: true)
        #expect(store.error == nil)
        #expect(try context.fetch(FetchDescriptor<HealthSyncState>()).first?.routeAnchor == Data([2]))
        #expect(try context.fetch(FetchDescriptor<HealthSyncState>()).first?.pendingRouteIDs == [route])
        await source.prepare(routes: [], imports: [:])
        await store.sync(context: context, automatic: true)
        #expect(await source.anchors == [nil, nil, Data([2])])
        #expect(await source.importedIDs == [route])
    }

    @Test func notificationAfterFirstSyncDoesNotImmediatelyRetryFailedRoutes() async throws {
        let container = try database(), context = ModelContext(container)
        let source = FakeHealthSource()
        let good = UUID(), waiting = UUID(), new = UUID()
        let tile = GridTile(x: 8186, y: 5448)
        let imports = [good: ImportedRoute(workoutID: UUID(), workoutDate: Date(), tiles: [tile]),
                       new: ImportedRoute(workoutID: UUID(), workoutDate: Date(), tiles: [tile])]
        await source.prepare(routes: [good, waiting, good], imports: imports, failures: [waiting])
        let store = GridStore(importer: source)
        await store.connect(context: context)
        await source.prepare(routes: [], imports: imports, failures: [waiting])
        await store.activate(context: context)
        await source.notify()
        #expect(await source.importedIDs == [good, waiting])
        await source.prepare(routes: [new], imports: imports, failures: [waiting])
        await source.notify()
        #expect(await source.importedIDs == [good, waiting, new])
        #expect(store.workoutCount == 2)
        #expect(try context.fetch(FetchDescriptor<HealthSyncState>()).first?.pendingRouteIDs == [waiting])
        // Automatic retries resume after the cooldown, even with no new data.
        let state = try #require(context.fetch(FetchDescriptor<HealthSyncState>()).first)
        state.pendingRetryAfter = .distantPast
        try context.save()
        await source.prepare(routes: [], imports: imports, failures: [waiting])
        await source.notify()
        #expect(await source.importedIDs == [good, waiting, new, waiting])
        await store.deactivate()
    }

    @Test func firstCollectedDateUsesEarliestWorkoutIncludingLateHistory() async throws {
        let container = try database(), context = ModelContext(container)
        let source = FakeHealthSource()
        let recent = UUID(), older = UUID(), tile = GridTile(x: 8186, y: 5448)
        let recentDate = Date(timeIntervalSince1970: 1743465600), olderDate = Date(timeIntervalSince1970: 1704067200)
        await source.prepare(routes: [recent], imports: [recent: ImportedRoute(workoutID: UUID(), workoutDate: recentDate, tiles: [tile])])
        let store = GridStore(importer: source)
        await store.connect(context: context)
        #expect(store.firstCollectedDates[tile] == recentDate)
        await source.prepare(routes: [older], imports: [older: ImportedRoute(workoutID: UUID(), workoutDate: olderDate, tiles: [tile])])
        await store.sync(context: context)
        #expect(store.firstCollectedDates[tile] == olderDate)
        let restored = GridStore(importer: source)
        restored.load(from: ModelContext(container))
        #expect(restored.firstCollectedDates[tile] == olderDate)
        #expect(restored.firstCollectedDates[GridTile(x: 1, y: 1)] == nil)
        restored.showDemo()
        restored.closeDemo(context: ModelContext(container))
        #expect(restored.firstCollectedDates[tile] == olderDate)
    }
}

private actor FakeHealthSource: HealthDataSource {
    private var routes: [UUID] = []
    private var imports: [UUID: ImportedRoute] = [:]
    private var failures = Set<UUID>()
    private var callback: (@Sendable () async -> Void)?
    private(set) var anchors: [Data?] = []
    private(set) var importedIDs: [UUID] = []
    var isObserving: Bool { callback != nil }

    func prepare(routes: [UUID], imports: [UUID: ImportedRoute], failures: Set<UUID> = []) {
        self.routes = routes; self.imports = imports; self.failures = failures
    }
    func authorize() async throws {}
    func changes(after anchor: Data?) async throws -> HealthRouteBatch {
        anchors.append(anchor)
        return HealthRouteBatch(routeIDs: routes, nextAnchor: Data([UInt8(anchors.count)]))
    }
    func importRoute(id: UUID) async throws -> ImportedRoute? {
        importedIDs.append(id)
        if failures.contains(id) { throw HealthImportError.routeNotReady }
        return imports[id]
    }
    func observeChanges(_ onChange: @escaping @Sendable () async -> Void) async { callback = onChange }
    func stopObserving() async { callback = nil }
    func notify() async { await callback?() }
}

private final class TestResources: NSObject {}
