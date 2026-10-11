//
//  GridQuestApp.swift
//  GridQuest
//
//  Created by James Coverdale on 10/10/2026.
//

import SwiftUI
import SwiftData

@main
struct GridQuestApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            ImportedWorkout.self,
            HealthSyncState.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: ProcessInfo.processInfo.arguments.contains("--demo"))

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
