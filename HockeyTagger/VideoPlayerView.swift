import SwiftUI
import AVKit

struct VideoPlayerView: View {
    @Bindable var viewModel: TaggingViewModel
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Player Layer
            VideoPlayerRepresentable(player: viewModel.player)
                .background(Color.black)
            
            // Timecode Overlay
            // Moved to top-left to avoid covering AVPlayer controls at bottom
            Text(formatTime(viewModel.currentTime))
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.6))
                .cornerRadius(6)
                .padding(12)
                .allowsHitTesting(false) // Pass clicks through to player

            if viewModel.isTagKeyHeld {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                    Text("TAGGING \(viewModel.activeTagLabel ?? "")")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.65))
                .clipShape(Capsule())
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.togglePlay()
        }
    }
    
    func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Double(seconds).truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%05.2f", m, s)
    }
}

struct VideoTimelineView: View {
    @Bindable var viewModel: TaggingViewModel

    var body: some View {
        let window = visibleWindow()
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    thumbnailStrip(width: geo.size.width, window: window)

                    if case .clipEdit(let clip) = viewModel.mode {
                        let startX = xPosition(for: clip.startTime, width: geo.size.width, window: window)
                        let endX = xPosition(for: clip.endTime, width: geo.size.width, window: window)
                        Rectangle()
                            .fill(Color.yellow.opacity(0.20))
                            .frame(width: max(2, endX - startX), height: geo.size.height)
                            .offset(x: max(0, startX), y: 0)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.yellow.opacity(0.95), lineWidth: 3)
                            .frame(width: max(2, endX - startX), height: geo.size.height)
                            .offset(x: max(0, startX), y: 0)
                    }

                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 4, height: geo.size.height)
                        .offset(x: max(0, min(geo.size.width - 4, xPosition(for: viewModel.currentTime, width: geo.size.width, window: window))))
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            viewModel.seek(to: time(for: value.location.x, width: geo.size.width, window: window))
                        }
                )
            }
            .frame(height: 68)
            .onAppear {
                updateZoomFrames(for: window)
            }
            .onChange(of: timelineZoomRequestKey(for: window)) { _, _ in
                updateZoomFrames(for: window)
            }

            HStack {
                Text(formatTime(window.lowerBound))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatTime(viewModel.currentTime))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatTime(window.upperBound))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func thumbnailStrip(width: Double, window: ClosedRange<Double>) -> some View {
        let isZoomMode = isZoomedMode
        let sourceThumbnails = isZoomMode ? viewModel.zoomTimelineThumbnails : viewModel.timelineThumbnails
        let totalDuration = max(viewModel.duration, 0.001)
        let startProgress = max(0, min(1, window.lowerBound / totalDuration))
        let endProgress = max(startProgress + 0.0001, min(1, window.upperBound / totalDuration))
        let visibleProgress = max(0.0001, endProgress - startProgress)
        let scale = 1.0 / visibleProgress

        return HStack(spacing: 1) {
            if sourceThumbnails.isEmpty {
                ForEach(0..<12, id: \.self) { _ in
                    Rectangle()
                        .fill(Color.gray.opacity(0.25))
                }
            } else {
                ForEach(Array(sourceThumbnails.enumerated()), id: \.offset) { _, image in
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: .infinity)
        .scaleEffect(x: isZoomMode ? 1.0 : scale, y: 1, anchor: .leading)
        .offset(x: isZoomMode ? 0 : -startProgress * width * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .overlay(alignment: .center) {
            if isZoomMode {
                if viewModel.isGeneratingZoomTimelineThumbnails && sourceThumbnails.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            } else if viewModel.isGeneratingTimelineThumbnails && sourceThumbnails.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    private var isZoomedMode: Bool {
        if case .clipEdit = viewModel.mode { return true }
        return false
    }

    private func timelineZoomRequestKey(for window: ClosedRange<Double>) -> String {
        if case .clipEdit(let clip) = viewModel.mode {
            return "\(clip.id.uuidString):\(window.lowerBound):\(window.upperBound)"
        }
        return "normal"
    }

    private func updateZoomFrames(for window: ClosedRange<Double>) {
        if isZoomedMode {
            viewModel.generateZoomTimelineThumbnails(for: window)
        } else {
            viewModel.clearZoomTimelineThumbnails()
        }
    }

    private func visibleWindow() -> ClosedRange<Double> {
        let totalDuration = max(viewModel.duration, 0)
        guard totalDuration > 0 else { return 0...1 }

        if case .clipEdit(let clip) = viewModel.mode {
            let leadIn = max(0, clip.startTime - 10.0)
            let leadOut = min(totalDuration, clip.endTime + 10.0)
            if leadOut > leadIn {
                return leadIn...leadOut
            }
        }

        return 0...totalDuration
    }

    private func xPosition(for time: Double, width: Double, window: ClosedRange<Double>) -> Double {
        let span = max(0.001, window.upperBound - window.lowerBound)
        let progress = (time - window.lowerBound) / span
        let clamped = max(0, min(1, progress))
        return clamped * width
    }

    private func time(for x: Double, width: Double, window: ClosedRange<Double>) -> Double {
        guard width > 0 else { return window.lowerBound }
        let span = max(0.001, window.upperBound - window.lowerBound)
        let clampedX = max(0, min(width, x))
        let progress = clampedX / width
        let mapped = window.lowerBound + (progress * span)
        return max(0, min(viewModel.duration, mapped))
    }

    private func formatTime(_ seconds: Double) -> String {
        let safeSeconds = max(0, seconds.isFinite ? seconds : 0)
        let m = Int(safeSeconds) / 60
        let s = Double(safeSeconds).truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%05.2f", m, s)
    }

}

struct VideoPlayerRepresentable: NSViewRepresentable {
    var player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        // Updates handled via player reference
    }
}
