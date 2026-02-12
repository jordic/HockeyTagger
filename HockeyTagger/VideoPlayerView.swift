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
        }
    }
    
    func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Double(seconds).truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%05.2f", m, s)
    }
}

struct VideoPlayerRepresentable: NSViewRepresentable {
    var player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline // Show default controls
        view.videoGravity = .resizeAspect
        return view
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        // Updates handled via player reference
    }
}