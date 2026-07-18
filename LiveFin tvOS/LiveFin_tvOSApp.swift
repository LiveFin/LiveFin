//
//  LiveFin_tvOSApp.swift
//  LiveFin tvOS
//
//  Created by KPGamingz on 12/13/25.
//

import SwiftUI
import CoreData

@main
struct LiveFin_tvOSApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
