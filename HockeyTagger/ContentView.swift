import SwiftUI
import AVKit
import Combine
import UniformTypeIdentifiers

// --- DATA MODEL ---
struct Clip: Codable, Identifiable, Equatable {
    let id: UUID
    var label: String
    var startTime: Double
    var endTime: Double
    
    init(label: String, startTime: Double, endTime: Double) {
        self.id = UUID()
        self.label = label
        self.startTime = startTime
        self.endTime = endTime
    }
}


// --- VIEW MODEL (Logic) ---
class TaggingViewModel: ObservableObject {
    @Published var player = AVPlayer()
    @Published var clips: [Clip] = []
    @Published var videoURL: URL?
    @Published var currentTime: String = "00:00:00"
    @Published var isPlaying = false
    @Published var exportStatus: String = ""
    @Published var showingExportAlert = false
    @Published var duration: Double = 0.0
    @Published var selectedClipID: UUID? = nil
    
    private var timeObserver: Any?
    private var previewStopTime: Double? = nil
    
    // Config
    let preRoll: Double = 8.0
    let postRoll: Double = 4.0
    
    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self = self else { return }
            self.currentTime = self.formatTime(time.seconds)
            
            if self.isPlaying, let stopTime = self.previewStopTime {
                if time.seconds >= stopTime {
                    self.player.pause()
                    self.isPlaying = false
                    self.previewStopTime = nil
                }
            }
        }
    }
    
    deinit {
        videoURL?.stopAccessingSecurityScopedResource()
    }
    
    func loadVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        
        if panel.runModal() == .OK, let url = panel.url {
            if let oldUrl = self.videoURL {
                oldUrl.stopAccessingSecurityScopedResource()
            }
            
            let accessGranted = url.startAccessingSecurityScopedResource()
            if !accessGranted { return }
            
            self.videoURL = url
            let asset = AVAsset(url: url)
            self.duration = CMTimeGetSeconds(asset.duration)
            
            let item = AVPlayerItem(url: url)
            self.player.replaceCurrentItem(with: item)
            self.clips = []
            self.player.play()
            self.isPlaying = true
        }
    }
    
    func updateClip(id: UUID, start: Double?, end: Double?) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        
        if let s = start {
            clips[index].startTime = max(0, min(s, clips[index].endTime - 0.1))
        }
        if let e = end {
            clips[index].endTime = min(duration, max(e, clips[index].startTime + 0.1))
        }
    }
    
    func togglePlay() {
        previewStopTime = nil
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }
    
    func seek(seconds: Double) {
        let current = player.currentTime().seconds
        let newTime = current + seconds
        player.seek(to: CMTime(seconds: newTime, preferredTimescale: 600))
    }
    
    func addTag(label: String) -> UUID {
        guard let _ = videoURL else { return UUID() }
        
        let current = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        
        let start = max(0, current - preRoll)
        let end = min(duration, current + postRoll)
        
        let newClip = Clip(label: label, startTime: start, endTime: end)
        clips.append(newClip)
        return newClip.id
    }
    
    func jumpToClip(_ clip: Clip) {
        self.previewStopTime = clip.endTime
        player.seek(to: CMTime(seconds: clip.startTime, preferredTimescale: 600))
        player.play()
        isPlaying = true
    }
    
    func saveTags() {
        guard !clips.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = (videoURL?.deletingPathExtension().lastPathComponent ?? "Session") + "_Tags"
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                let data = try encoder.encode(clips)
                try data.write(to: url)
                self.exportStatus = "Tags saved successfully!"
                self.showingExportAlert = true
            } catch {
                self.exportStatus = "Error saving: \(error.localizedDescription)"
                self.showingExportAlert = true
            }
        }
    }
    
    func loadTags() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                let loadedClips = try decoder.decode([Clip].self, from: data)
                self.clips = loadedClips
            } catch {
                self.exportStatus = "Error loading: \(error.localizedDescription)"
                self.showingExportAlert = true
            }
        }
    }
    
    func exportClips() {
        guard let sourceURL = videoURL else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        
        if panel.runModal() == .OK, let baseFolderURL = panel.url {
            let accessGranted = baseFolderURL.startAccessingSecurityScopedResource()
            let videoName = sourceURL.deletingPathExtension().lastPathComponent
            let exportFolderURL = baseFolderURL.appendingPathComponent("\(videoName)_Highlights")
            
            try? FileManager.default.createDirectory(at: exportFolderURL, withIntermediateDirectories: true)
            
            self.exportStatus = "Exporting \(clips.count) clips..."
            self.showingExportAlert = true
            
            Task {
                let asset = AVAsset(url: sourceURL)
                for (index, clip) in self.clips.enumerated() {
                    let safeLabel = clip.label.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
                    let filename = String(format: "%02d_%@.mp4", index + 1, safeLabel)
                    let outputURL = exportFolderURL.appendingPathComponent(filename)
                    try? FileManager.default.removeItem(at: outputURL)
                    
                    guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { continue }
                    
                    exportSession.outputURL = outputURL
                    exportSession.outputFileType = .mp4
                    
                    let start = CMTime(seconds: clip.startTime, preferredTimescale: 600)
                    let dur = CMTime(seconds: clip.endTime - clip.startTime, preferredTimescale: 600)
                    exportSession.timeRange = CMTimeRange(start: start, duration: dur)
                    
                    await exportSession.export()
                }
                
                await MainActor.run {
                    if accessGranted { baseFolderURL.stopAccessingSecurityScopedResource() }
                    self.exportStatus = "Success! Clips saved."
                    NSWorkspace.shared.activateFileViewerSelecting([exportFolderURL])
                }
            }
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sc = s % 60
        return String(format: "%02d:%02d:%02d", h, m, sc)
    }
}

// --- MAIN UI ---
struct ContentView: View {
    @ObservedObject var vm = TaggingViewModel()
    @FocusState private var focusedField: UUID?
    
    var body: some View {
        HSplitView {
            // LEFT SIDE: Video
            ZStack(alignment: .bottomLeading) {
                Color.black
                if vm.videoURL != nil {
                    VideoPlayer(player: vm.player)
                } else {
                    Button("Open Video File (⌘O)") { vm.loadVideo() }
                        .controlSize(.large)
                }
                
                Text(vm.currentTime)
                    .font(.system(.title2, design: .monospaced))
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                    .padding()
                    .foregroundColor(.white)
            }
            .frame(minWidth: 600, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
            
            // RIGHT SIDE: Controls
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    HStack {
                        if vm.videoURL == nil {
                            Button("Load (⌘O)") { vm.loadVideo() }
                        } else {
                            Text(vm.videoURL?.lastPathComponent ?? "").truncationMode(.middle)
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    
                    HStack {
                        Button("Load Tags", action: vm.loadTags).buttonStyle(.bordered)
                        Spacer()
                        Button("Export All", action: vm.exportClips)
                            .buttonStyle(.borderedProminent).tint(.green)
                            .disabled(vm.clips.isEmpty)
                    }
                }
                .padding()
                .background(Color(nsColor: .windowBackgroundColor))
                
                Divider()
                
                HStack(spacing: 12) {
                    TagButton(label: "Highlight", shortcut: "1", color: .blue) { triggerTag("Highlight") }
                    TagButton(label: "Goal", shortcut: "2", color: .orange) { triggerTag("Goal") }
                    TagButton(label: "Defense", shortcut: "3", color: .purple) { triggerTag("Defense") }
                }
                .padding()
                
                Divider()
                
                List($vm.clips) { $clip in
                    HStack {
                        Image(systemName: "play.circle.fill")
                            .foregroundColor(.gray)
                            .onTapGesture { vm.jumpToClip(clip) }
                        
                        Text(String(format: "%.0fs", clip.startTime))
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                            .frame(width: 40)
                        
                        TextField("Label", text: $clip.label)
                            .textFieldStyle(.plain)
                            .focused($focusedField, equals: clip.id)
                            .onSubmit { focusedField = nil }
                        
                        Spacer()
                        
                        Button(action: {
                            if let idx = vm.clips.firstIndex(of: clip) { vm.clips.remove(at: idx) }
                        }) {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                        .opacity(0.5)
                    }
                    .padding(.vertical, 4)
                }
                
                Text("Space: Play | 1,2,3: Tag")
                    .font(.caption).foregroundColor(.secondary).padding()
            }
            .frame(minWidth: 300, maxWidth: 400)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .background(WindowAccessor { window in
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let isEditing = (window?.firstResponder as? NSTextView) != nil
                if event.characters == " " && event.modifierFlags.contains(.control) {
                    vm.togglePlay()
                    return nil
                }
                if isEditing { return event }
                
                switch event.characters {
                case " ":
                    vm.togglePlay()
                    return nil
                case "1":
                    triggerTag("Highlight")
                    return nil
                case "2":
                    triggerTag("Goal")
                    return nil
                case "3":
                    triggerTag("Defense")
                    return nil
                case String(UnicodeScalar(NSRightArrowFunctionKey)!):
                    vm.seek(seconds: 5)
                    return nil
                case String(UnicodeScalar(NSLeftArrowFunctionKey)!):
                    vm.seek(seconds: -5)
                    return nil
                default:
                    return event
                }
            }
        })
        .alert(isPresented: $vm.showingExportAlert) {
            Alert(title: Text("Status"), message: Text(vm.exportStatus), dismissButton: .default(Text("OK")))
        }
    }
    
    func triggerTag(_ label: String) {
        let newID = vm.addTag(label: label)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            focusedField = newID
        }
    }
}

struct TagButton: View {
    let label: String
    let shortcut: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack {
                Text(shortcut).font(.caption).bold().opacity(0.7)
                Text(label).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .tint(color)
        .controlSize(.large)
    }
}

struct WindowAccessor: NSViewRepresentable {
    var callback: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.callback(view.window) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}