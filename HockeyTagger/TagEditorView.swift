import SwiftUI
import AVFoundation

struct TagEditorView: View {
    @Bindable var viewModel: TaggingViewModel
    @Bindable var clip: Clip
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Tag Editor")
                    .font(.headline)
                Spacer()
                Button("Done (D)") {
                    viewModel.exitEditMode()
                }
                .keyboardShortcut("d", modifiers: [])
                .buttonStyle(.borderedProminent)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Label")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Label", text: $clip.label)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Start")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatTime(clip.startTime))
                        .font(.system(.body, design: .monospaced))
                    HStack(spacing: 6) {
                        Button("-0.5s (Q)") { viewModel.adjustClipStart(clip, by: -0.5) }
                            .keyboardShortcut("q", modifiers: [])
                        Button("+0.5s (W)") { viewModel.adjustClipStart(clip, by: 0.5) }
                            .keyboardShortcut("w", modifiers: [])
                    }
                    .controlSize(.small)
                    Button("Set To Playhead (E)") {
                        clip.startTime = min(viewModel.currentTime, clip.endTime - 0.1)
                    }
                    .keyboardShortcut("e", modifiers: [])
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("End")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatTime(clip.endTime))
                        .font(.system(.body, design: .monospaced))
                    HStack(spacing: 6) {
                        Button("-0.5s (A)") { viewModel.adjustClipEnd(clip, by: -0.5) }
                            .keyboardShortcut("a", modifiers: [])
                        Button("+0.5s (S)") { viewModel.adjustClipEnd(clip, by: 0.5) }
                            .keyboardShortcut("s", modifiers: [])
                    }
                    .controlSize(.small)
                    Button("Set To Playhead (F)") {
                        clip.endTime = max(viewModel.currentTime, clip.startTime + 0.1)
                    }
                    .keyboardShortcut("f", modifiers: [])
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button("Jump To Start (J)") {
                    viewModel.seek(to: clip.startTime)
                }
                .keyboardShortcut("j", modifiers: [])
                Button("Replay Loop (R)") {
                    viewModel.seek(to: clip.startTime)
                    viewModel.player.play()
                }
                .keyboardShortcut("r", modifiers: [])
                Spacer()
                Text("Duration \(String(format: "%.1fs", clip.endTime - clip.startTime))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Double(seconds).truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%04.1f", m, s)
    }
}
