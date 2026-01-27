//
//  HockeyTaggerApp.swift
//  HockeyTagger
//
//  Created by Jordi Collell Puig on 27/1/26.
//

import SwiftUI
import CoreData

@main
struct HockeyTaggerApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
