import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var viewModel: TaggingViewModel
    
    var body: some View {
        HSplitView {
            // Left: Video Player Area
            VStack(spacing: 0) {
                // Video Player takes all available space
                ZStack {
                    Color.black
                    VideoPlayerView(viewModel: viewModel)
                }
                .focusable()
                .onKeyPress(.space, action: {
                    viewModel.togglePlay()
                    return .handled
                })
                .onKeyPress(.leftArrow, action: {
                    viewModel.seek(to: viewModel.currentTime - 2)
                    return .handled
                })
                .onKeyPress(.rightArrow, action: {
                    viewModel.seek(to: viewModel.currentTime + 2)
                    return .handled
                })
                // Add keyboard shortcuts for tagging directly to the player focus area
                .onKeyPress(KeyEquivalent("1"), action: {
                    viewModel.addTag(label: "Highlight")
                    return .handled
                })
                .onKeyPress(KeyEquivalent("2"), action: {
                    viewModel.addTag(label: "Goal")
                    return .handled
                })
                .onKeyPress(KeyEquivalent("3"), action: {
                    viewModel.addTag(label: "Defense")
                    return .handled
                })
                .onKeyPress(.escape, action: {
                    if case .clipEdit = viewModel.mode {
                        viewModel.exitEditMode()
                        return .handled
                    }
                    return .ignored
                })
                .focusEffectDisabled() // Remove default focus ring visual
                
                // Editor Panel below video (if active)
                if case .clipEdit(let clip) = viewModel.mode {
                    TagEditorView(viewModel: viewModel, clip: clip)
                        .transition(.move(edge: .bottom))
                }
            }
            .frame(minWidth: 500, minHeight: 400)
            
            // Right: Sidebar Controls (White/Light Background)
            Group {
                if let project = viewModel.currentProject {
                    TagListView(project: project, viewModel: viewModel)
                        .id(project.id) // Force recreate on project change
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "film")
                            .font(.system(size: 48))
                            .foregroundColor(.gray)
                        Text("No Video Loaded")
                            .font(.title2)
                            .foregroundColor(.gray)
                        Button("Open Video...") {
                            viewModel.promptForVideo()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)
                }
            }
            .frame(minWidth: 300, maxWidth: 400)
            .focusable() // Allow sidebar to accept focus
            .onTapGesture {
                // Ensure clicking background focuses the sidebar
                // This helps steal focus from the video player ZStack
            }
        }
        .onAppear {
            viewModel.setModelContext(modelContext)
            viewModel.loadLastOpenProject()
        }
        .onChange(of: modelContext) { _, newContext in
            viewModel.setModelContext(newContext)
        }
        .alert("Export Status", isPresented: $viewModel.showingExportAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.exportMessage ?? "")
        }
        .overlay {
            if viewModel.isExporting {
                ZStack {
                    Color.black.opacity(0.4)
                    VStack(spacing: 20) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Exporting Clips...")
                            .font(.headline)
                    }
                    .padding(40)
                    .background(.ultraThinMaterial)
                    .cornerRadius(20)
                }
                .ignoresSafeArea()
            }
        }
    }
}