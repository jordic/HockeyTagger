import SwiftUI
import SwiftData
import UniformTypeIdentifiers

@main
struct SportsTaggerApp: App {
    @State private var viewModel = TaggingViewModel()
    
    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
        .modelContainer(for: [Project.self, Clip.self])
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video...") {
                    viewModel.promptForVideo()
                }
                .keyboardShortcut("o", modifiers: .command)
                
                Menu("Open Recent") {
                    RecentProjectsMenu(viewModel: viewModel)
                }
            }
            
            CommandGroup(after: .importExport) {
                Button("Export All Clips (Video)...") {
                    viewModel.promptForExport()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(viewModel.currentProject == nil)
                
                Divider()
                
                Button("Import Tags (JSON)...") {
                    viewModel.promptForImportJSON()
                }
                .disabled(viewModel.currentProject == nil)
                
                Button("Export Tags (JSON)...") {
                    viewModel.promptForExportJSON()
                }
                .disabled(viewModel.currentProject == nil)
            }
        }
    }
}

// Separate view for the query to work correctly
struct RecentProjectsMenu: View {
    @Bindable var viewModel: TaggingViewModel
    // Using ViewModel cache instead of @Query inside commands to ensure context availability
    
    var body: some View {
        if viewModel.recentProjects.isEmpty {
            Button("No Recent Projects") {}
                .disabled(true)
        } else {
            ForEach(viewModel.recentProjects) { project in
                Button(project.videoName) {
                    viewModel.loadProject(project)
                }
            }
            
            Divider()
            
            Button("Clear Menu") {
                // Optional: Clear recents logic if desired
            }
            .disabled(true)
        }
    }
}
