import SwiftUI

struct DownloadVideoSheet: View {
    @Bindable var viewModel: TaggingViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download Video")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Paste an `hd.m3u8` playlist URL. The app will download segments to a temp file, then ask where to save it.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("https://example.com/path/hd.m3u8", text: $viewModel.downloadURLInput)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Download") {
                    viewModel.startDownloadFromInput()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.downloadURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
