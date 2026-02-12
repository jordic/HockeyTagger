import SwiftUI
import AVFoundation

struct TagEditorView: View {
    @Bindable var viewModel: TaggingViewModel
    @Bindable var clip: Clip
    
    var body: some View {
        HStack(spacing: 16) {
            // Label
            TextField("Label", text: $clip.label)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            
            Divider().frame(height: 32)
            
            // Trimming Controls (Compact)
            HStack(spacing: 24) {
                // Start Group
                HStack(spacing: 8) {
                    Text("Start")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text(formatTime(clip.startTime))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 70, alignment: .leading)
                    
                    HStack(spacing: 2) {
                        Button("-") { viewModel.adjustClipStart(clip, by: -0.5) }
                        Button("+") { viewModel.adjustClipStart(clip, by: 0.5) }
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
                
                // End Group
                HStack(spacing: 8) {
                    Text("End")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text(formatTime(clip.endTime))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 70, alignment: .leading)
                    
                    HStack(spacing: 2) {
                        Button("-") { viewModel.adjustClipEnd(clip, by: -0.5) }
                        Button("+") { viewModel.adjustClipEnd(clip, by: 0.5) }
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
            }
            
            Spacer()
            
            // Actions
            HStack(spacing: 16) {
                Button(action: {
                    viewModel.seek(to: clip.startTime)
                    viewModel.player.play()
                }) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Replay Loop")
                
                Button("Done") {
                    viewModel.exitEditMode()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .background(Material.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.white.opacity(0.1))
        }
    }
    
    func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Double(seconds).truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%04.1f", m, s)
    }
}