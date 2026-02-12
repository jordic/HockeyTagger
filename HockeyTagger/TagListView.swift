import SwiftUI
import SwiftData

struct TagListView: View {
    @Bindable var viewModel: TaggingViewModel
    @Query(sort: \Clip.endTime, order: .reverse) var clips: [Clip]
    let project: Project
    
    // Filter clips by current project
    init(project: Project, viewModel: TaggingViewModel) {
        self.project = project
        self.viewModel = viewModel
        let projectId = project.id
        _clips = Query(filter: #Predicate { $0.project?.id == projectId }, sort: \.endTime, order: .reverse)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top Controls Area
            VStack(spacing: 12) {
                // Row 1: Load Video / Export All
                HStack {
                    Button("Load Video") {
                        viewModel.promptForVideo()
                    }
                    .buttonStyle(.bordered)
                    
                    Spacer()
                    
                    Button("Export All") {
                        viewModel.promptForExport()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
                
                // Row 2: Load Tags / Save Tags (Placeholder functions as logic is implicit in SwiftData)
                HStack {
                    Button("Load Tags") { /* Implicit in project load */ }
                        .disabled(true)
                    Spacer()
                    Button("Save Tags") { viewModel.saveChanges() }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .buttonStyle(.bordered)
            }
            .padding()
            .background(Color.white)
            
            Divider()
            
            // Tag Buttons (Large, Pill-shaped)
            VStack(spacing: 10) {
                TagButton(label: "Highlight", color: .blue, shortcut: "1") {
                    viewModel.addTag(label: "Highlight")
                }
                
                TagButton(label: "Goal", color: .orange, shortcut: "2") {
                    viewModel.addTag(label: "Goal")
                }
                
                TagButton(label: "Defense", color: .purple, shortcut: "3") {
                    viewModel.addTag(label: "Defense")
                }
            }
            .padding()
            .background(Color.white)
            
            Divider()
            
            // List Header
            HStack {
                Text("Clips (\(clips.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .background(Color.white)
            
            // Clip List
            List {
                ForEach(clips) { clip in
                    ClipRow(clip: clip, viewModel: viewModel)
                        .listRowInsets(EdgeInsets()) // Full width for playhead
                        .listRowSeparator(.hidden)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        viewModel.deleteClip(clips[index])
                    }
                }
            }
            .listStyle(.plain)
            .background(Color.white)
        }
        .background(Color.white)
    }
}

struct TagButton: View {
    let label: String
    let color: Color
    let shortcut: KeyEquivalent
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.headline)
                    .fontWeight(.bold)
                Spacer()
                Text("(\(shortcut.character))")
                    .font(.caption)
                    .opacity(0.6)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: [])
    }
}

struct ClipRow: View {
    let clip: Clip
    var viewModel: TaggingViewModel
    
    var body: some View {
        ZStack(alignment: .leading) {
            // Playback Progress Background
            GeometryReader { geo in
                if viewModel.currentProject?.id == clip.project?.id,
                   viewModel.currentTime >= clip.startTime,
                   viewModel.currentTime <= clip.endTime {
                    
                    let duration = clip.endTime - clip.startTime
                    let progress = (viewModel.currentTime - clip.startTime) / duration
                    Color.blue.opacity(0.1)
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, progress))))
                }
            }
            
            // Content
            HStack(spacing: 12) {
                // Play Icon
                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                // Time
                Text(formatTime(clip.startTime))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                
                // Label (Non-editable)
                Text(clip.label)
                    .font(.body)
                    .fontWeight(.medium)
                
                Spacer()
                
                // Duration
                Text(String(format: "%.1fs", clip.endTime - clip.startTime))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                
                // Delete Button
                Button(action: {
                    viewModel.deleteClip(clip)
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(.red.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.enterEditMode(for: clip)
        }
    }
    
    func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
