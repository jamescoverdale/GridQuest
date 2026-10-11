import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = GridStore()
    @State private var showGrid = true
    @State private var showAbout = false
    @State private var selectedTile: GridTile?
    @State private var location = UserLocation()
    @State private var cameraRequest: MapCameraRequest?

    var body: some View {
        ZStack {
            GridMapView(tiles: store.tiles, squares: store.squares, showGrid: showGrid,
                        frameRequest: store.frameRequest, userLocation: location.point,
                        cameraRequest: cameraRequest, selectedTile: $selectedTile)
                .ignoresSafeArea()
            if store.tiles.isEmpty && !store.isConnected && !store.isImporting {
                welcome
            }
        }
        .safeAreaInset(edge: .top) { header }
        .safeAreaInset(edge: .bottom) { dashboard }
        .task {
            store.load(from: modelContext)
            if ProcessInfo.processInfo.arguments.contains("--demo") { store.showDemo() }
            else {
                location.locate()
                await store.activate(context: modelContext)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            Task {
                if phase == .active {
                    if !store.isDemo { location.locate() }
                    await store.activate(context: modelContext)
                } else { await store.deactivate() }
            }
        }
        .sheet(isPresented: $showAbout) { about }
        .alert("Unable to complete sync", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .alert("Location access", isPresented: Binding(get: { location.message != nil }, set: { if !$0 { location.message = nil } })) {
            Button("OK") { location.message = nil }
        } message: { Text(location.message ?? "") }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.3x3.fill").foregroundStyle(.orange).font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("GridQuest").font(.title2.bold())
                    Text(store.isDemo ? "SAMPLE GRID" : "MAKE EVERY OUTING COUNT")
                        .font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(1.2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { showGrid.toggle() } label: { Image(systemName: showGrid ? "grid" : "map") }
                .accessibilityLabel(showGrid ? "Hide grid lines" : "Show grid lines")
            Button {
                cameraRequest = MapCameraRequest(target: .home)
                location.locate(jumpHome: true)
            } label: { Image(systemName: "location.fill") }
                .accessibilityLabel("Jump home")
            Menu {
                if store.isConnected && !store.isDemo {
                    Button("Sync now", systemImage: "arrow.triangle.2.circlepath") { sync() }.disabled(store.isImporting)
                    Button("Check all Health history", systemImage: "clock.arrow.circlepath") {
                        Task { await store.sync(context: modelContext, fullHistory: true) }
                    }.disabled(store.isImporting)
                }
                Button("About GridQuest", systemImage: "info.circle") { showAbout = true }
            } label: {
                if store.isImporting { ProgressView().controlSize(.small) }
                else { Image(systemName: "ellipsis.circle") }
            }
            .accessibilityLabel("GridQuest options")
        }
        .buttonStyle(.borderless)
        .tint(.primary)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "map.fill").font(.system(size: 38)).foregroundStyle(.orange)
            Text("Your next square\nis out there.").font(.largeTitle.bold()).multilineTextAlignment(.center)
            Text("Turn your walks, runs and rides into a map of everywhere you’ve explored.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Connect Apple Health", systemImage: "heart.fill") { Task { await store.connect(context: modelContext) } }
                .buttonStyle(.borderedProminent).tint(.orange).controlSize(.large)
                .accessibilityIdentifier("connectHealth")
                .disabled(store.isConnecting)
            if store.isConnecting { ProgressView("Connecting…") }
            Button("Explore a sample grid") { store.showDemo() }.tint(.primary)
                .accessibilityIdentifier("sampleGrid")
            Text("Your workout routes and grid stay on this device.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
        .padding(24)
    }

    private var dashboard: some View {
        VStack(spacing: 14) {
            if let selectedTile {
                HStack {
                    Image(systemName: store.tiles.contains(selectedTile) ? "checkmark.square.fill" : "square.dashed")
                        .foregroundStyle(store.tiles.contains(selectedTile) ? .orange : .secondary)
                    VStack(alignment: .leading) {
                        Text(store.tiles.contains(selectedTile) ? "Collected square" : "A new square to explore").font(.subheadline.bold())
                        Text("\(selectedTile.center.latitude, specifier: "%.4f")°, \(selectedTile.center.longitude, specifier: "%.4f")°")
                            .font(.caption).foregroundStyle(.secondary)
                        if let date = store.firstCollectedDates[selectedTile] {
                            Text("First collected \(date.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("firstCollectedDate")
                        }
                    }
                    Spacer()
                    Button { self.selectedTile = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .tint(.secondary).accessibilityLabel("Close square details")
                }
            }
            HStack {
                stat("Squares", value: store.tiles.count.formatted(), symbol: "square.grid.3x3.fill", color: .orange)
                Spacer()
                Button {
                    selectedTile = nil
                    cameraRequest = MapCameraRequest(target: .largest)
                } label: {
                    stat("Largest square", value: "\(store.squares.first?.size ?? 0) × \(store.squares.first?.size ?? 0)", symbol: "square.dashed.inset.filled", color: .teal)
                }
                .buttonStyle(.plain).disabled(store.squares.isEmpty)
                .accessibilityIdentifier("jumpLargestSquare")
                .accessibilityHint("Zoom to your largest filled square")
                Spacer()
                stat(store.isDemo ? "Sample" : "Workouts", value: store.isDemo ? "DEMO" : store.workoutCount.formatted(), symbol: "figure.walk", color: .secondary)
            }
            if store.isImporting {
                ProgressView(value: store.progress).tint(.orange)
                Text(store.status ?? "Importing…").font(.caption).foregroundStyle(.secondary)
            } else if let status = store.status {
                Text(status).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if store.isDemo {
                HStack {
                    Text("Sample data · your Health history is unchanged").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Close") { store.closeDemo(context: modelContext); selectedTile = nil }.font(.subheadline.bold())
                }
            } else if !store.isImporting && store.status == nil, let lastSync = store.lastSync {
                Text("Updated \(lastSync, style: .relative) ago").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private func stat(_ title: String, value: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(color)
            Text(value).font(.system(.title2, design: .rounded, weight: .bold)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private var about: some View {
        NavigationStack {
            List {
                Section("Build your grid") {
                    Text("A square is collected when a workout route visits or crosses it. Connect Apple Health once; your grid then updates when you open GridQuest and when new routes arrive while it’s running.")
                    Text("The teal outline marks one of your largest completely filled squares.")
                    Text("Tap the largest-square stat to jump to it. Jump home centers the map on your current location.")
                }
                Section("Your data") {
                    Text("GridQuest reads workouts and GPS routes. It does not write to Apple Health or send your workout data to a server.")
                    Text("If no routes appear, check GridQuest’s access in Health → your profile → Apps. Some workouts include duration and distance without a GPS route. Apple keeps read-access decisions private, so GridQuest cannot tell whether access was denied.")
                }
                Section("Inspired by Squadra") {
                    Text("GridQuest is a modern clone of Squadra by Bert Temme, bringing its square-collecting adventure to Apple Health workouts.")
                    Link("Visit the Squadra website", destination: URL(string: "https://bertt.github.io/squadra/")!)
                }
            }
            .navigationTitle("About GridQuest")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showAbout = false } } }
        }
    }

    private func sync() { Task { await store.sync(context: modelContext) } }
}

#Preview {
    ContentView().modelContainer(for: [ImportedWorkout.self, HealthSyncState.self], inMemory: true)
}
