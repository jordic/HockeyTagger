import SwiftUI
import SwiftData
import AVKit

@Observable
class TaggingViewModel {
    var player = AVPlayer()
    var currentProject: Project?
    var isPlaying = false
    var currentTime: Double = 0.0
    var duration: Double = 1.0 // Avoid divide by zero
    
    // Mode
    enum Mode {
        case normal
        case clipEdit(Clip)
    }
    var mode: Mode = .normal
    
    // Dependencies
    var modelContext: ModelContext?
    
    // Recent Projects Cache for Menu
    var recentProjects: [Project] = []
    
    private var timeObserver: Any?
    private var itemObserver: NSKeyValueObservation?
    
    // Security Scoped Resource tracking
    private var currentVideoURL: URL?
    
    // Playback State Tracking
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var isSeeking = false
    
    // Export Status Tracking
    var exportMessage: String?
    var showingExportAlert = false
    var isExporting = false
    
    init() {
        // Setup periodic time observer
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            self.currentTime = time.seconds
            self.checkPlaybackBounds()
        }
        
        // Setup Play/Pause observer to keep UI in sync with Native Controls
        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.isPlaying = (player.timeControlStatus == .playing)
            }
        }
    }
    
    deinit {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
        timeControlStatusObserver?.invalidate()
        stopAccessingCurrentVideo()
    }
    
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
        fetchRecentProjects()
    }
    
    @MainActor
    func fetchRecentProjects() {
        guard let context = modelContext else { return }
        var descriptor = FetchDescriptor<Project>(sortBy: [SortDescriptor(\.lastOpened, order: .reverse)])
        descriptor.fetchLimit = 10
        
        do {
            recentProjects = try context.fetch(descriptor)
        } catch {
            print("Failed to fetch recent projects: \(error)")
        }
    }
    
    // MARK: - Video Loading
    
    @MainActor
    func loadVideo(url: URL) {
        print("Loading video: \(url.path)")
        // Stop accessing previous video if any
        stopAccessingCurrentVideo()
        
        // Start accessing security scoped resource
        guard url.startAccessingSecurityScopedResource() else {
            print("Failed to access security scoped resource: \(url)")
            // Proceed anyway? The OS might still allow it if it came from OpenPanel recently.
            return
        }
        currentVideoURL = url
        
        // Check for existing project or create new
        if let context = modelContext {
            fetchOrConnectProject(for: url, context: context)
        } else {
            print("CRITICAL: ModelContext is nil in TaggingViewModel.loadVideo. Cannot save project.")
        }
        
        // Setup Player
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        
        // Observe duration
        itemObserver = item.observe(\.duration, changeHandler: { [weak self] item, _ in
            guard let self = self else { return }
            Task { @MainActor in
                if item.duration.isValid && !item.duration.isIndefinite {
                    self.duration = item.duration.seconds
                }
            }
        })
        
        isPlaying = false
    }
    
    @MainActor
    func loadProject(_ project: Project) {
        // Access property
        if let url = BookmarkManager.resolveBookmark(project.videoBookmark) {
            self.currentProject = project
            project.lastOpened = Date()
            
            // Persist last opened project ID
            UserDefaults.standard.set(project.id.uuidString, forKey: "lastOpenedProjectID")
            
            // Save context to persist lastOpened date update
            try? modelContext?.save()
            fetchRecentProjects()
            
            loadVideo(url: url)
        } else {
            print("Could not resolve bookmark for project: \(project.videoName)")
            // Optionally handle missing file UI here
        }
    }
    
    @MainActor
    func loadLastOpenProject() {
        guard let context = modelContext else {
            print("loadLastOpenProject: ModelContext is nil")
            return
        }
        
        guard let uuidString = UserDefaults.standard.string(forKey: "lastOpenedProjectID") else {
            print("loadLastOpenProject: No last opened project ID found in UserDefaults")
            return
        }
        
        guard let uuid = UUID(uuidString: uuidString) else {
            print("loadLastOpenProject: Invalid UUID string in UserDefaults: \(uuidString)")
            return
        }
        
        print("loadLastOpenProject: Attempting to load project with ID: \(uuid)")
        
        let descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.id == uuid })
        do {
            if let project = try context.fetch(descriptor).first {
                print("loadLastOpenProject: Found project: \(project.videoName). Loading...")
                loadProject(project)
            } else {
                print("loadLastOpenProject: Project with ID \(uuid) not found in database.")
            }
        } catch {
            print("loadLastOpenProject: Failed to fetch last open project: \(error)")
        }
    }
    
    @MainActor
    private func fetchOrConnectProject(for url: URL, context: ModelContext) {
        let name = url.lastPathComponent
        
        // Fetch project by name (simplistic matching, but sufficient for scope)
        let descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.videoName == name })
        
        do {
            let projects = try context.fetch(descriptor)
            if let existing = projects.first {
                print("Found existing project for \(name)")
                self.currentProject = existing
                existing.lastOpened = Date()
                
                // Self-heal: Update the bookmark with the fresh URL we just got access to
                if let newBookmark = BookmarkManager.makeBookmark(for: url) {
                    print("Updating bookmark for existing project.")
                    existing.videoBookmark = newBookmark
                }
                
                // Persist updates
                try? context.save()
                
                // Persist last opened project ID
                UserDefaults.standard.set(existing.id.uuidString, forKey: "lastOpenedProjectID")
                
                fetchRecentProjects()
            } else {
                print("Creating new project for \(name)")
                createNewProject(url: url, context: context)
            }
        } catch {
            print("Error fetching projects: \(error)")
            createNewProject(url: url, context: context)
        }
    }
    
    @MainActor
    private func createNewProject(url: URL, context: ModelContext) {
        print("Creating new project for \(url.lastPathComponent)")
        var bookmark: Data
        
        if let data = BookmarkManager.makeBookmark(for: url) {
            bookmark = data
        } else {
            print("Warning: Could not create bookmark for \(url). Persistence across restarts may fail.")
            bookmark = Data() // Fallback empty data to allow runtime usage
        }
        
        let newProject = Project(videoBookmark: bookmark, videoName: url.lastPathComponent)
        context.insert(newProject)
        // Save immediately to ensure ID is generated and state propagated
        try? context.save() 
        self.currentProject = newProject
        
        // Persist last opened project ID
        UserDefaults.standard.set(newProject.id.uuidString, forKey: "lastOpenedProjectID")
        
        fetchRecentProjects()
    }
    
    private func stopAccessingCurrentVideo() {
        if let url = currentVideoURL {
            url.stopAccessingSecurityScopedResource()
            currentVideoURL = nil
        }
    }
    
    // MARK: - Playback Control
    
    func togglePlay() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
        // isPlaying is updated by observer
    }
    
    func seek(to time: Double, completion: @escaping () -> Void = {}) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        isSeeking = true
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.isSeeking = false
                completion()
            }
        }
    }
    
    func checkPlaybackBounds() {
        guard !isSeeking else { return } // Prevent fighting with active seek
        
        if case .clipEdit(let clip) = mode {
            if currentTime >= clip.endTime {
                // Loop back to start
                seek(to: clip.startTime) { [weak self] in
                    self?.player.play()
                }
            } else if currentTime < clip.startTime {
                // If drifted before start, snap back
                // Allow small tolerance? For now, strict.
                // seek(to: clip.startTime) // disabling strict pre-start check to allow easier scrubbing
            }
        }
    }
    
    // MARK: - Tagging
    
    func addTag(label: String) {
        guard let project = currentProject else { return }
        let start = max(0, currentTime - 2.0) // Default 2s before
        let end = min(duration, currentTime + 2.0) // Default 2s after
        
        let newClip = Clip(label: label, startTime: start, endTime: end)
        newClip.project = project
        modelContext?.insert(newClip)
    }
    
    func deleteClip(_ clip: Clip) {
        modelContext?.delete(clip)
    }
    
    func adjustClipStart(_ clip: Clip, by amount: Double) {
        clip.startTime += amount
        // Ensure valid range
        if clip.startTime >= clip.endTime { clip.startTime = clip.endTime - 0.1 }
        // Seek to new start to preview frame
        seek(to: clip.startTime) { [weak self] in
            // Pause to inspect
             self?.player.pause()
        }
    }

    func adjustClipEnd(_ clip: Clip, by amount: Double) {
        clip.endTime += amount
        // Ensure valid range
        if clip.endTime <= clip.startTime { clip.endTime = clip.startTime + 0.1 }
        // Seek to new end to preview frame
        seek(to: clip.endTime) { [weak self] in
            // Pause to inspect
            self?.player.pause()
        }
    }
    
    func enterEditMode(for clip: Clip) {
        mode = .clipEdit(clip)
        seek(to: clip.startTime) { [weak self] in
            self?.player.play()
        }
    }
    
    func exitEditMode() {
        mode = .normal
        player.pause()
        // isPlaying updated by observer
    }
    
    func saveChanges() {
        // SwiftData autosaves, but we can explicitly save if needed
        try? modelContext?.save()
    }
    
    // MARK: - Export Video Clips
    
    func exportClips(to directory: URL) async {
        guard let project = currentProject, let videoURL = BookmarkManager.resolveBookmark(project.videoBookmark) else {
            print("Export failed: No project or video URL")
            return
        }
        
        await MainActor.run {
            self.isExporting = true
            self.exportMessage = nil
        }
        
        // Start accessing both source and destination
        let videoAccess = videoURL.startAccessingSecurityScopedResource()
        let directoryAccess = directory.startAccessingSecurityScopedResource()
        
        print("Source access: \(videoAccess), Destination access: \(directoryAccess)")
        
        defer {
            if videoAccess { videoURL.stopAccessingSecurityScopedResource() }
            if directoryAccess { directory.stopAccessingSecurityScopedResource() }
            
            Task { @MainActor in
                self.isExporting = false
            }
        }

        print("Exporting \(project.clips.count) clips to \(directory.path)")
        
        var successCount = 0
        var failCount = 0
        
        let asset = AVAsset(url: videoURL)
        do {
            let tracks = try await asset.load(.tracks)
            if tracks.isEmpty {
                print("Export failed: No tracks found in video")
                await MainActor.run {
                    self.exportMessage = "Export failed: No tracks found in video."
                    self.showingExportAlert = true
                }
                return
            }
        } catch {
            print("Export failed: Error loading tracks: \(error)")
            await MainActor.run {
                self.exportMessage = "Export failed: \(error.localizedDescription)"
                self.showingExportAlert = true
            }
            return
        }
        
        for clip in project.clips {
            let safeLabel = clip.label
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            
            let filename = "\(safeLabel)_\(Int(clip.startTime))-\(Int(clip.endTime)).mp4"
            let finalOutputURL = directory.appendingPathComponent(filename)
            
            // Use a temporary URL for the export session to avoid sandbox write issues
            let tempOutputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            
            print("Exporting clip to temp: \(tempOutputURL.path)")
            
            // Remove existing temp if any (shouldn't happen with UUID)
            try? FileManager.default.removeItem(at: tempOutputURL)
            
            guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                print("Export failed: Could not create export session for \(filename)")
                failCount += 1
                continue
            }
            
            exportSession.outputURL = tempOutputURL
            exportSession.outputFileType = .mp4
            
            let startTime = CMTime(seconds: clip.startTime, preferredTimescale: 600)
            let duration = CMTime(seconds: clip.endTime - clip.startTime, preferredTimescale: 600)
            exportSession.timeRange = CMTimeRange(start: startTime, duration: duration)
            
            await exportSession.export()
            
            if let error = exportSession.error {
                print("Export session failed for \(filename): \(error.localizedDescription)")
                failCount += 1
            } else {
                // Export to temp succeeded, now move to final destination
                do {
                    // Start accessing the directory again specifically for the copy operation
                    let writeAccess = finalOutputURL.startAccessingSecurityScopedResource()
                    defer { if writeAccess { finalOutputURL.stopAccessingSecurityScopedResource() } }

                    print("Saving clip to: \(finalOutputURL.path)")
                    
                    if FileManager.default.fileExists(atPath: finalOutputURL.path) {
                        try FileManager.default.removeItem(at: finalOutputURL)
                    }
                    
                    try FileManager.default.copyItem(at: tempOutputURL, to: finalOutputURL)
                    print("Successfully saved clip to: \(finalOutputURL.path)")
                    successCount += 1
                } catch {
                    print("Failed to save clip to final destination: \(error.localizedDescription)")
                    failCount += 1
                }
            }
            
            // Cleanup temp file if it still exists
            try? FileManager.default.removeItem(at: tempOutputURL)
        }
        
        print("Export process finished")
        
        await MainActor.run {
            if failCount == 0 {
                self.exportMessage = "Successfully exported \(successCount) clips!"
            } else {
                self.exportMessage = "Export finished with \(successCount) successes and \(failCount) failures."
            }
            self.showingExportAlert = true
        }
    }
    
    // MARK: - JSON Import/Export
    
    func exportTagsJSON(to url: URL) {
        guard let project = currentProject else { return }
        let dtos = project.clips.map { ClipDTO(label: $0.label, startTime: $0.startTime, endTime: $0.endTime) }
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(dtos)
            try data.write(to: url)
        } catch {
            print("Failed to export JSON: \(error)")
        }
    }
    
    @MainActor
    func importTagsJSON(from url: URL) {
        guard let project = currentProject, let context = modelContext else { return }
        
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let dtos = try decoder.decode([ClipDTO].self, from: data)
            
            for dto in dtos {
                let newClip = Clip(label: dto.label, startTime: dto.startTime, endTime: dto.endTime)
                newClip.project = project
                context.insert(newClip)
            }
            print("Imported \(dtos.count) clips")
        } catch {
            print("Failed to import JSON: \(error)")
        }
    }
    
    // MARK: - User Interactions (Panels)
    
    @MainActor
    func promptForVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        
        if panel.runModal() == .OK, let url = panel.url {
            loadVideo(url: url)
        }
    }
    
    @MainActor
    func promptForExport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Clips"
        
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await exportClips(to: url)
            }
        }
    }
    
    @MainActor
    func promptForExportJSON() {
        guard let project = currentProject else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(project.videoName)_tags.json"
        
        if panel.runModal() == .OK, let url = panel.url {
            exportTagsJSON(to: url)
        }
    }
    
    @MainActor
    func promptForImportJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let url = panel.url {
            importTagsJSON(from: url)
        }
    }
}
