import SwiftUI
import SwiftData
import AVKit
import AppKit
import UniformTypeIdentifiers

@Observable
class TaggingViewModel {
    var player = AVPlayer()
    var currentProject: Project?
    var isPlaying = false
    var currentTime: Double = 0.0
    var duration: Double = 1.0 // Avoid divide by zero
    var timelineThumbnails: [NSImage] = []
    var zoomTimelineThumbnails: [NSImage] = []
    var isGeneratingTimelineThumbnails = false
    var isGeneratingZoomTimelineThumbnails = false
    
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
    private var timelineThumbnailTask: Task<Void, Never>?
    private var zoomTimelineThumbnailTask: Task<Void, Never>?
    
    // Security Scoped Resource tracking
    private var currentVideoURL: URL?
    
    // Playback State Tracking
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var isSeeking = false
    private var activeTagKeyPressStart: [String: Double] = [:]
    var activeTagLabel: String?
    var isTagKeyHeld = false
    
    // Export Status Tracking
    var exportMessage: String?
    var showingExportAlert = false
    var isExporting = false

    // Download Status Tracking
    var showingDownloadVideoSheet = false
    var downloadURLInput = ""
    var isDownloadingVideo = false
    var downloadProgress: Double = 0
    var downloadStatusText = "Preparing download..."
    var downloadMessage: String?
    var showingDownloadAlert = false
    var canCancelDownload = false
    
    private var downloadTask: Task<Void, Never>?
    private var downloadTempDirectoryURL: URL?
    private var downloadExportSession: AVAssetExportSession?
    private var downloadProgressTask: Task<Void, Never>?
    
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
        downloadTask?.cancel()
        downloadProgressTask?.cancel()
        downloadExportSession?.cancelExport()
        timelineThumbnailTask?.cancel()
        zoomTimelineThumbnailTask?.cancel()
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
        currentTime = 0
        duration = 1.0
        zoomTimelineThumbnails = []
        generateTimelineThumbnails(for: url)
        
        // Observe duration
        itemObserver = item.observe(\.duration, changeHandler: { [weak self] item, _ in
            guard let self = self else { return }
            Task { @MainActor in
                if item.duration.isValid && !item.duration.isIndefinite {
                    self.duration = item.duration.seconds
                    if self.timelineThumbnails.isEmpty && !self.isGeneratingTimelineThumbnails {
                        self.generateTimelineThumbnails(for: url)
                    }
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
        timelineThumbnailTask?.cancel()
        zoomTimelineThumbnailTask?.cancel()
        timelineThumbnails = []
        zoomTimelineThumbnails = []
        isGeneratingTimelineThumbnails = false
        isGeneratingZoomTimelineThumbnails = false
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
        let safeTime = max(0, min(time, duration))
        let cmTime = CMTime(seconds: safeTime, preferredTimescale: 600)
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
        createTag(label: label, start: start, end: end, project: project)
    }

    func tagKeyDown(label: String) {
        guard activeTagKeyPressStart[label] == nil else { return }
        activeTagKeyPressStart[label] = currentTime
        activeTagLabel = label
        isTagKeyHeld = true
    }

    func tagKeyUp(label: String) {
        guard let pressStart = activeTagKeyPressStart.removeValue(forKey: label) else {
            // If we didn't capture key down for any reason, preserve previous tap behavior.
            addTag(label: label)
            return
        }
        isTagKeyHeld = !activeTagKeyPressStart.isEmpty
        activeTagLabel = activeTagKeyPressStart.keys.first

        let pressEnd = max(pressStart + 0.01, currentTime)
        let heldDuration = pressEnd - pressStart

        // Quick tap preserves existing default behavior.
        if heldDuration < 0.20 {
            addTag(label: label)
            return
        }

        guard let project = currentProject else { return }
        let start = max(0, min(pressStart, pressEnd))
        let end = min(duration, max(pressStart, pressEnd))
        createTag(label: label, start: start, end: end, project: project)
    }

    private func createTag(label: String, start: Double, end: Double, project: Project) {
        let safeStart = max(0, min(start, end - 0.01))
        let safeEnd = min(duration, max(end, safeStart + 0.01))

        let newClip = Clip(label: label, startTime: safeStart, endTime: safeEnd)
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
        // Force mode refresh so selecting a different clip while editing always rebinds UI.
        mode = .normal
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

    // MARK: - Clip Sharing

    @MainActor
    func shareClip(_ clip: Clip) {
        Task {
            await exportAndShareClip(clip)
        }
    }

    private func exportAndShareClip(_ clip: Clip) async {
        guard let project = currentProject, let videoURL = BookmarkManager.resolveBookmark(project.videoBookmark) else {
            await MainActor.run {
                exportMessage = "Unable to share clip: video source is unavailable."
                showingExportAlert = true
            }
            return
        }

        let videoAccess = videoURL.startAccessingSecurityScopedResource()
        defer {
            if videoAccess { videoURL.stopAccessingSecurityScopedResource() }
        }

        let safeLabel = clip.label
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let fileName = "\(safeLabel)_\(Int(clip.startTime))-\(Int(clip.endTime)).mp4"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)_\(fileName)")

        try? FileManager.default.removeItem(at: tempURL)

        let asset = AVAsset(url: videoURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            await MainActor.run {
                exportMessage = "Unable to share clip: failed to create export session."
                showingExportAlert = true
            }
            return
        }

        exportSession.outputURL = tempURL
        exportSession.outputFileType = .mp4
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: clip.startTime, preferredTimescale: 600),
            duration: CMTime(seconds: max(0.1, clip.endTime - clip.startTime), preferredTimescale: 600)
        )

        await exportSession.export()

        if let error = exportSession.error {
            await MainActor.run {
                exportMessage = "Clip export failed: \(error.localizedDescription)"
                showingExportAlert = true
            }
            return
        }

        await MainActor.run {
            let picker = NSSharingServicePicker(items: [tempURL])
            if let view = NSApp.keyWindow?.contentView {
                picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            } else {
                exportMessage = "Clip exported to temp, but no active window was available for sharing picker.\n\(tempURL.path)"
                showingExportAlert = true
            }
        }
    }

    // MARK: - Timeline Thumbnails

    private func generateTimelineThumbnails(for url: URL) {
        timelineThumbnailTask?.cancel()
        timelineThumbnails = []
        isGeneratingTimelineThumbnails = true

        timelineThumbnailTask = Task(priority: .utility) { [weak self] in
            guard let self = self else { return }
            let thumbnails = self.buildTimelineThumbnails(for: url, timeRange: nil, preferredCount: nil)

            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.timelineThumbnails = thumbnails
                self.isGeneratingTimelineThumbnails = false
            }
        }
    }

    func generateZoomTimelineThumbnails(for window: ClosedRange<Double>) {
        guard let url = currentVideoURL else { return }

        zoomTimelineThumbnailTask?.cancel()
        isGeneratingZoomTimelineThumbnails = true

        zoomTimelineThumbnailTask = Task(priority: .utility) { [weak self] in
            guard let self = self else { return }
            let thumbnails = self.buildTimelineThumbnails(for: url, timeRange: window, preferredCount: 36)

            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.zoomTimelineThumbnails = thumbnails
                self.isGeneratingZoomTimelineThumbnails = false
            }
        }
    }

    func clearZoomTimelineThumbnails() {
        zoomTimelineThumbnailTask?.cancel()
        zoomTimelineThumbnails = []
        isGeneratingZoomTimelineThumbnails = false
    }

    private func buildTimelineThumbnails(
        for url: URL,
        timeRange: ClosedRange<Double>?,
        preferredCount: Int?
    ) -> [NSImage] {
        let asset = AVAsset(url: url)
        let totalSeconds = asset.duration.seconds

        guard totalSeconds.isFinite, totalSeconds > 0 else { return [] }

        let startSecond = max(0, min(totalSeconds, timeRange?.lowerBound ?? 0))
        let endSecond = max(startSecond, min(totalSeconds, timeRange?.upperBound ?? totalSeconds))
        let windowSeconds = max(0.001, endSecond - startSecond)

        let imageCount: Int
        if let preferredCount {
            imageCount = max(8, preferredCount)
        } else {
            imageCount = max(8, min(24, Int(windowSeconds / 12.0)))
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 220, height: 124)

        var images: [NSImage] = []
        images.reserveCapacity(imageCount)

        for idx in 0..<imageCount {
            if Task.isCancelled { return [] }
            let progress = Double(idx) / Double(max(imageCount - 1, 1))
            let second = startSecond + (progress * windowSeconds)
            let cmTime = CMTime(seconds: second, preferredTimescale: 600)

            do {
                let cgImage = try generator.copyCGImage(at: cmTime, actualTime: nil)
                images.append(NSImage(cgImage: cgImage, size: .zero))
            } catch {
                continue
            }
        }

        return images
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
    func promptForDownloadVideo() {
        downloadURLInput = ""
        showingDownloadVideoSheet = true
    }

    @MainActor
    func startDownloadFromInput() {
        let rawInput = downloadURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizeInputURLString(rawInput)
        guard let inputURL = URL(string: normalized), inputURL.scheme != nil else {
            downloadMessage = "Invalid URL. Please paste a full playlist URL."
            showingDownloadAlert = true
            return
        }

        showingDownloadVideoSheet = false
        downloadTask?.cancel()
        downloadTask = Task { [weak self] in
            await self?.downloadVideoFromPlaylistURL(inputURL)
        }
    }

    @MainActor
    func cancelDownloadVideo() {
        guard isDownloadingVideo else { return }
        downloadStatusText = "Cancelling download..."
        downloadTask?.cancel()
        downloadProgressTask?.cancel()
        downloadExportSession?.cancelExport()
    }

    private func downloadVideoFromPlaylistURL(_ inputURL: URL) async {
        await MainActor.run {
            isDownloadingVideo = true
            canCancelDownload = true
            downloadProgress = 0
            downloadStatusText = "Fetching playlist..."
        }

        do {
            try Task.checkCancellation()
            let rootPlaylist = try await fetchPlaylistText(from: inputURL)
            let mediaPlaylistCandidates = resolveMediaPlaylistURLs(from: rootPlaylist, baseURL: inputURL)
            var resolvedMediaURL: URL?
            var mediaPlaylistText: String?

            for candidate in mediaPlaylistCandidates {
                do {
                    let text = try await fetchPlaylistText(from: candidate)
                    resolvedMediaURL = candidate
                    mediaPlaylistText = text
                    break
                } catch {
                    continue
                }
            }

            guard let mediaPlaylistURL = resolvedMediaURL, let mediaPlaylistText else {
                throw NSError(
                    domain: "VideoDownload",
                    code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "Could not load any media playlist variant from the provided URL."]
                )
            }
            let _ = mediaPlaylistText // keep validation path explicit
            let tempResult: (URL, String)
            do {
                tempResult = try await exportPlaylistToTempFile(mediaPlaylistURL)
            } catch {
                if isAVFoundationOperationStopped(error) {
                    await MainActor.run {
                        downloadStatusText = "Exporter stopped. Falling back to segment download..."
                        downloadProgress = 0
                    }
                    tempResult = try await fallbackDownloadSegmentsToTempFile(
                        mediaPlaylistText: mediaPlaylistText,
                        mediaPlaylistURL: mediaPlaylistURL
                    )
                } else {
                    throw error
                }
            }
            let (tempFileURL, suggestedName) = tempResult

            await MainActor.run {
                isDownloadingVideo = false
                canCancelDownload = false
            }

            await MainActor.run {
                promptForSaveDownloadedVideo(tempURL: tempFileURL, suggestedName: suggestedName)
                downloadTask = nil
            }
        } catch {
            await MainActor.run {
                isDownloadingVideo = false
                canCancelDownload = false
                if Task.isCancelled || isCancellationError(error) {
                    cleanupDownloadTempFiles()
                    downloadMessage = "Download cancelled."
                } else {
                    cleanupDownloadTempFiles()
                    downloadMessage = "Download failed: \(error.localizedDescription)"
                }
                showingDownloadAlert = true
                downloadTask = nil
            }
        }
    }

    private func exportPlaylistToTempFile(_ playlistURL: URL) async throws -> (URL, String) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        await MainActor.run {
            downloadTempDirectoryURL = tempDir
            downloadProgress = 0
            downloadStatusText = "Downloading and muxing video..."
        }

        let asset = AVAsset(url: playlistURL)
        let preferredPresets = [AVAssetExportPresetHighestQuality, AVAssetExportPresetPassthrough]
        guard let preset = preferredPresets.first(where: { AVAssetExportSession.exportPresets(compatibleWith: asset).contains($0) }) else {
            throw NSError(
                domain: "VideoDownload",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "This HLS stream is not exportable with available presets."]
            )
        }

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw NSError(
                domain: "VideoDownload",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Could not create export session for the HLS playlist."]
            )
        }

        let fileType: AVFileType
        if exportSession.supportedFileTypes.contains(.mp4) {
            fileType = .mp4
        } else if exportSession.supportedFileTypes.contains(.mov) {
            fileType = .mov
        } else if let first = exportSession.supportedFileTypes.first {
            fileType = first
        } else {
            throw NSError(
                domain: "VideoDownload",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "No supported output file types for this stream."]
            )
        }

        let ext: String
        switch fileType {
        case .mp4: ext = "mp4"
        case .mov: ext = "mov"
        default: ext = "mp4"
        }

        let baseName = playlistURL.deletingPathExtension().lastPathComponent
        let suggestedName = (baseName.isEmpty ? "downloaded_video" : baseName) + ".\(ext)"
        let outputURL = tempDir.appendingPathComponent(suggestedName)
        try? FileManager.default.removeItem(at: outputURL)

        exportSession.outputURL = outputURL
        exportSession.outputFileType = fileType
        exportSession.shouldOptimizeForNetworkUse = true

        await MainActor.run {
            downloadExportSession = exportSession
        }

        downloadProgressTask?.cancel()
        downloadProgressTask = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                let progress = Double(exportSession.progress)
                await MainActor.run {
                    self.downloadProgress = progress
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        await exportSession.export()
        downloadProgressTask?.cancel()
        await MainActor.run {
            downloadExportSession = nil
        }

        if exportSession.status == .cancelled {
            throw CancellationError()
        }

        if exportSession.status != .completed {
            let exportError = exportSession.error
            if let exportError {
                throw exportError
            }
            throw NSError(
                domain: "VideoDownload",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Export failed with status \(exportSession.status.rawValue)."]
            )
        }

        await MainActor.run {
            downloadProgress = 1.0
        }
        return (outputURL, suggestedName)
    }

    private func fallbackDownloadSegmentsToTempFile(
        mediaPlaylistText: String,
        mediaPlaylistURL: URL
    ) async throws -> (URL, String) {
        let segmentURLs = parseSegmentURLs(from: mediaPlaylistText, baseURL: mediaPlaylistURL)
        guard !segmentURLs.isEmpty else {
            throw NSError(
                domain: "VideoDownload",
                code: 14,
                userInfo: [NSLocalizedDescriptionKey: "No downloadable segments found in media playlist."]
            )
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        await MainActor.run {
            downloadTempDirectoryURL = tempDir
            downloadStatusText = "Downloading HLS segments..."
            downloadProgress = 0
        }

        let segmentDirectory = tempDir.appendingPathComponent("segments", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentDirectory, withIntermediateDirectories: true)

        let initSegmentURL = parseInitializationSegmentURL(from: mediaPlaylistText, baseURL: mediaPlaylistURL)
        let initSegmentPath: URL? = (initSegmentURL != nil) ? tempDir.appendingPathComponent("init.seg") : nil
        if let initURL = initSegmentURL, let initPath = initSegmentPath {
            let (tmp, response) = try await URLSession.shared.download(from: initURL)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw NSError(
                    domain: "VideoDownload",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to download initialization segment (\(http.statusCode))."]
                )
            }
            if FileManager.default.fileExists(atPath: initPath.path) {
                try FileManager.default.removeItem(at: initPath)
            }
            try FileManager.default.moveItem(at: tmp, to: initPath)
        }

        let totalCount = segmentURLs.count
        let maxParallelDownloads = 8
        var completedCount = 0
        var batchStart = 0

        while batchStart < totalCount {
            try Task.checkCancellation()
            let batchEnd = min(batchStart + maxParallelDownloads, totalCount)

            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in batchStart..<batchEnd {
                    let segmentURL = segmentURLs[index]
                    let segmentOutputURL = segmentDirectory.appendingPathComponent(String(format: "%06d.seg", index))
                    group.addTask {
                        try Task.checkCancellation()
                        var request = URLRequest(url: segmentURL)
                        request.timeoutInterval = 60
                        let (tempSegmentURL, response) = try await URLSession.shared.download(for: request)
                        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                            throw NSError(
                                domain: "VideoDownload",
                                code: http.statusCode,
                                userInfo: [NSLocalizedDescriptionKey: "Failed to download segment (\(http.statusCode)):\n\(segmentURL.absoluteString)"]
                            )
                        }
                        if FileManager.default.fileExists(atPath: segmentOutputURL.path) {
                            try FileManager.default.removeItem(at: segmentOutputURL)
                        }
                        try FileManager.default.moveItem(at: tempSegmentURL, to: segmentOutputURL)
                    }
                }

                for try await _ in group {
                    completedCount += 1
                    await MainActor.run {
                        downloadProgress = Double(completedCount) / Double(totalCount)
                        downloadStatusText = "Downloading segment \(completedCount) of \(totalCount)..."
                    }
                }
            }

            batchStart = batchEnd
        }

        let firstPath = segmentURLs.first?.lastPathComponent.lowercased() ?? ""
        let ext = firstPath.contains(".m4s") || initSegmentURL != nil ? "mp4" : "ts"
        let baseName = mediaPlaylistURL.deletingPathExtension().lastPathComponent
        let suggestedName = (baseName.isEmpty ? "downloaded_video" : baseName) + ".\(ext)"
        let outputURL = tempDir.appendingPathComponent(suggestedName)
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)

        let fileHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? fileHandle.close() }

        await MainActor.run {
            downloadStatusText = "Merging segments..."
            downloadProgress = 0
        }

        if let initPath = initSegmentPath {
            let initData = try Data(contentsOf: initPath)
            try fileHandle.write(contentsOf: initData)
        }

        for index in 0..<totalCount {
            try Task.checkCancellation()
            let segPath = segmentDirectory.appendingPathComponent(String(format: "%06d.seg", index))
            let data = try Data(contentsOf: segPath)
            try fileHandle.write(contentsOf: data)
            await MainActor.run {
                downloadProgress = Double(index + 1) / Double(totalCount)
                downloadStatusText = "Merging segment \(index + 1) of \(totalCount)..."
            }
        }

        return (outputURL, suggestedName)
    }

    private func fetchPlaylistText(from url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: "VideoDownload",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Failed to fetch playlist (\(http.statusCode)):\n\(url.absoluteString)"]
            )
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "VideoDownload",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Playlist is not valid UTF-8 text."]
            )
        }
        return text
    }

    private func resolveMediaPlaylistURLs(from playlistText: String, baseURL: URL) -> [URL] {
        let lines = playlistText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let streamInfoLines = lines.enumerated().filter { $0.element.hasPrefix("#EXT-X-STREAM-INF") }
        if streamInfoLines.isEmpty {
            return [baseURL]
        }

        var candidateRelativePaths: [String] = []
        for (index, _) in streamInfoLines {
            let nextIndex = index + 1
            if nextIndex < lines.count {
                let nextLine = lines[nextIndex]
                if !nextLine.hasPrefix("#") {
                    candidateRelativePaths.append(nextLine)
                }
            }
        }

        if candidateRelativePaths.isEmpty {
            return [baseURL]
        }

        let preferredOrder = candidateRelativePaths.sorted { lhs, rhs in
            let lHD = lhs.lowercased().contains("hd.m3u8")
            let rHD = rhs.lowercased().contains("hd.m3u8")
            if lHD != rHD { return lHD && !rHD }
            return lhs < rhs
        }

        return preferredOrder.compactMap { resolveURL(from: $0, baseURL: baseURL) }
    }

    private func parseSegmentURLs(from playlistText: String, baseURL: URL) -> [URL] {
        let lines = playlistText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return lines.compactMap { line in
            guard !line.hasPrefix("#"), !line.lowercased().contains(".m3u8") else { return nil }
            return resolveURL(from: line, baseURL: baseURL)
        }
    }

    private func parseInitializationSegmentURL(from playlistText: String, baseURL: URL) -> URL? {
        let lines = playlistText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let mapLine = lines.first(where: { $0.hasPrefix("#EXT-X-MAP:") }) else { return nil }
        guard let range = mapLine.range(of: "URI=\"") else { return nil }
        let tail = mapLine[range.upperBound...]
        guard let endQuote = tail.firstIndex(of: "\"") else { return nil }
        let uri = String(tail[..<endQuote])
        return resolveURL(from: uri, baseURL: baseURL)
    }

    private func resolveURL(from rawPath: String, baseURL: URL) -> URL? {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        if let absolute = URL(string: path), absolute.scheme != nil {
            return absolute
        }

        if path.hasPrefix("//"), let scheme = baseURL.scheme {
            return URL(string: "\(scheme):\(path)")
        }

        if path.hasPrefix("/") {
            var comps = URLComponents()
            comps.scheme = baseURL.scheme
            comps.host = baseURL.host
            comps.port = baseURL.port
            comps.path = path
            return comps.url
        }

        if let relativeToFile = URL(string: path, relativeTo: baseURL)?.absoluteURL {
            return relativeToFile
        }

        let directoryBase = baseURL.deletingLastPathComponent()
        return URL(string: path, relativeTo: directoryBase)?.absoluteURL
    }

    private func normalizeInputURLString(_ value: String) -> String {
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            return value
        }
        return "https://\(value)"
    }

    @MainActor
    private func promptForSaveDownloadedVideo(tempURL: URL, suggestedName: String) {
        let panel = NSSavePanel()
        panel.prompt = "Save Video"
        panel.message = "Choose where to save the downloaded video."
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if suggestedName.lowercased().hasSuffix(".mov") {
            panel.allowedContentTypes = [UTType.quickTimeMovie]
        } else if suggestedName.lowercased().hasSuffix(".ts"),
                  let tsType = UTType(filenameExtension: "ts") {
            panel.allowedContentTypes = [tsType]
        } else {
            panel.allowedContentTypes = [UTType.mpeg4Movie]
        }

        if panel.runModal() == .OK, let destinationURL = panel.url {
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                cleanupDownloadTempFiles()
                downloadMessage = "Video downloaded successfully to:\n\(destinationURL.path)"
            } catch {
                downloadMessage = "Downloaded to temp, but failed to move file: \(error.localizedDescription)"
            }
        } else {
            downloadMessage = "Download completed, but save was cancelled. Temp file remains at:\n\(tempURL.path)"
            downloadTempDirectoryURL = nil
        }
        showingDownloadAlert = true
    }

    @MainActor
    private func cleanupDownloadTempFiles() {
        if let tempDir = downloadTempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDir)
        }
        downloadTempDirectoryURL = nil
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        return false
    }

    private func isAVFoundationOperationStopped(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain && nsError.code == -11838 {
            return true
        }
        let message = nsError.localizedDescription.lowercased()
        if message.contains("operation stopped") {
            return true
        }
        return false
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
