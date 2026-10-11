import Foundation
import Observation
import SwiftData

@MainActor @Observable
final class GridStore {
    private(set) var tiles = Set<GridTile>()
    private(set) var firstCollectedDates: [GridTile: Date] = [:]
    private(set) var squares: [GridSquare] = []
    private(set) var workoutCount = 0
    private(set) var isConnected = false
    private(set) var isImporting = false
    private(set) var isConnecting = false
    private(set) var isDemo = false
    private(set) var progress = 0.0
    private(set) var status: String?
    private(set) var lastSync: Date?
    var error: String?
    var frameRequest = 0
    private let importer: any HealthDataSource
    private var syncAgain = false
    private var isActive = false
    private var observationContext: ModelContext?

    init(importer: any HealthDataSource = HealthImporter()) { self.importer = importer }

    func load(from context: ModelContext) {
        do {
            let workouts = try context.fetch(FetchDescriptor<ImportedWorkout>())
            var dates: [GridTile: Date] = [:]
            for workout in workouts {
                for tile in try workout.tiles() {
                    dates[tile] = min(dates[tile] ?? workout.startDate, workout.startDate)
                }
            }
            firstCollectedDates = dates
            tiles = Set(dates.keys)
            workoutCount = workouts.count
            squares = TileCalculator.largestSquares(in: tiles)
            let state = try syncState(context)
            // Upgrade existing installations that have already imported Health data.
            if !state.isConnected && !workouts.isEmpty { state.isConnected = true; try context.save() }
            isConnected = state.isConnected
            lastSync = state.lastSync
        } catch { self.error = "Could not read your saved grid: \(error.localizedDescription)" }
    }

    func activate(context: ModelContext) async {
        isActive = true
        guard isConnected && !isDemo else { return }
        await startObserving(context: context)
        await sync(context: context, automatic: true)
    }

    func deactivate() async { isActive = false; observationContext = nil; await importer.stopObserving() }

    func connect(context: ModelContext) async {
        guard !isImporting && !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await importer.authorize()
            let state = try syncState(context)
            state.isConnected = true
            try context.save()
            isConnected = true
            isConnecting = false
            await sync(context: context)
            if isActive { await startObserving(context: context) }
        } catch { context.rollback(); self.error = error.localizedDescription }
    }

    func sync(context: ModelContext, automatic: Bool = false, fullHistory: Bool = false) async {
        guard isConnected && !isDemo else { return }
        if isImporting { if automatic { syncAgain = true }; return }
        isImporting = true
        progress = 0
        status = "Checking for new routes…"
        defer {
            isImporting = false
            if syncAgain {
                syncAgain = false
                if isActive { Task { await sync(context: context, automatic: true) } }
            }
        }
        do {
            let state = try syncState(context)
            if fullHistory { state.routeAnchor = nil; try context.save() }
            let batch = try await importer.changes(after: state.routeAnchor)
            var existing = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<ImportedWorkout>()).map { ($0.id, $0) })
            let processed = Set(existing.values.flatMap(\.routeIDs)).union(state.ignoredRouteIDs)
            let previousPending = Set(state.pendingRouteIDs).subtracting(processed)
            let retryDue = !automatic || fullHistory || (state.pendingRetryAfter ?? .distantPast) <= Date()
            var seen = processed
            let outstanding = (state.pendingRouteIDs + batch.routeIDs).filter { seen.insert($0).inserted }
            let missing = outstanding.filter { retryDue || !previousPending.contains($0) }
            // Journal outstanding IDs and advance the change token together, before
            // reading GPS. Failed routes no longer cause history to be scanned again.
            state.pendingRouteIDs = outstanding
            state.routeAnchor = batch.nextAnchor
            if !missing.isEmpty { state.pendingRetryAfter = Date().addingTimeInterval(60) }
            try context.save()
            var failures = 0
            var firstFailure: String?
            for (index, id) in missing.enumerated() {
                status = previousPending.contains(id) ? "Retrying route \(index + 1) of \(missing.count)…" : "Adding route \(index + 1) of \(missing.count)…"
                do {
                    if let imported = try await importer.importRoute(id: id) {
                        if let record = existing[imported.workoutID] {
                            record.tileData = try JSONEncoder().encode(Array(try record.tiles().union(imported.tiles)))
                            record.routeIDs.append(id)
                        } else {
                            let record = try ImportedWorkout(id: imported.workoutID, startDate: imported.workoutDate, tiles: imported.tiles)
                            record.routeIDs = [id]
                            context.insert(record)
                            existing[imported.workoutID] = record
                        }
                    } else {
                        state.ignoredRouteIDs.append(id)
                    }
                    state.pendingRouteIDs.removeAll { $0 == id }
                    try context.save()
                } catch {
                    context.rollback()
                    failures += 1
                    firstFailure = firstFailure ?? error.localizedDescription
                    existing = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<ImportedWorkout>()).map { ($0.id, $0) })
                }
                progress = Double(index + 1) / Double(max(1, missing.count))
            }
            if state.pendingRouteIDs.isEmpty {
                state.pendingRetryAfter = nil
                state.lastSync = Date()
            } else if !missing.isEmpty {
                // Start the cooldown after processing, including a long first import.
                state.pendingRetryAfter = Date().addingTimeInterval(60)
            }
            try context.save()
            load(from: context)
            if !state.pendingRouteIDs.isEmpty {
                status = "\(state.pendingRouteIDs.count) \(state.pendingRouteIDs.count == 1 ? "route" : "routes") waiting to sync. Saved routes are up to date."
                if failures > 0 && !automatic { error = firstFailure }
            } else if tiles.isEmpty {
                status = "No GPS routes yet. Check workout route access in Apple Health."
            } else {
                status = nil
            }
        } catch {
            context.rollback()
            status = "Couldn’t update your grid. We’ll retry when you return."
            if !automatic { self.error = error.localizedDescription }
        }
    }

    private func syncState(_ context: ModelContext) throws -> HealthSyncState {
        if let state = try context.fetch(FetchDescriptor<HealthSyncState>()).first { return state }
        let state = HealthSyncState()
        context.insert(state)
        try context.save()
        return state
    }

    private func startObserving(context: ModelContext) async {
        observationContext = context
        await importer.observeChanges { [weak self] in
            guard let self else { return }
            await self.healthChanged()
        }
    }

    private func healthChanged() async {
        guard isActive && !isDemo, let context = observationContext else { return }
        await sync(context: context, automatic: true)
    }

    func showDemo() {
        guard !isImporting else { return }
        isDemo = true
        let origin = GridTile(x: 8185, y: 5446)
        var sample = Set<GridTile>()
        for x in 0..<7 { for y in 0..<6 where !(x == 6 && y < 3) { sample.insert(GridTile(x: origin.x + x, y: origin.y + y)) } }
        for x in 7..<11 { sample.insert(GridTile(x: origin.x + x, y: origin.y + 3)) }
        for y in 6..<10 { sample.insert(GridTile(x: origin.x + 2, y: origin.y + y)) }
        tiles = sample
        firstCollectedDates = Dictionary(uniqueKeysWithValues: sample.map { ($0, Date(timeIntervalSince1970: 1743465600)) })
        squares = TileCalculator.largestSquares(in: sample)
        workoutCount = 0
        status = nil
        frameRequest += 1
    }

    func closeDemo(context: ModelContext) { isDemo = false; status = nil; load(from: context) }
}
