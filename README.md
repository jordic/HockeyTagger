# HockeyTagger

HockeyTagger is a macOS app for reviewing hockey video, creating timestamped tags, trimming clips, exporting highlights, and sharing selected clips.

## What It Does

- Load local videos and persist projects with SwiftData.
- Create tags quickly with keyboard shortcuts.
- Hold tag keys (`1`, `2`, `3`) to create clip ranges from key-down to key-up.
- Edit clip timing in the Tag Editor.
- Use an interactive timeline with:
  - playback playhead
  - zoomed clip context during editing
  - clip-region overlay
- Export all clips to video files.
- Import/export tags as JSON.
- Download HLS videos from playlist URLs (`.m3u8`) with progress and cancellation.
- Share a single clip to other apps (Messages, WhatsApp, etc.) from Tag Editor.

## Tech Stack

- SwiftUI
- SwiftData
- AVFoundation / AVKit
- macOS App Sandbox + user-selected file access

## Project Structure

- `HockeyTagger/ContentView.swift`: main split layout and global overlays.
- `HockeyTagger/VideoPlayerView.swift`: player view and timeline UI.
- `HockeyTagger/TagListView.swift`: clip list and tagging sidebar controls.
- `HockeyTagger/TagEditorView.swift`: clip editing and per-clip share action.
- `HockeyTagger/TaggingViewModel.swift`: playback, tagging, export, download logic.
- `HockeyTagger/HockeyTaggerApp.swift`: app entry point and menu commands.
- `HockeyTagger/Models.swift`: SwiftData models.

## Requirements

- Xcode 17+
- macOS 14.0+ deployment target

## Build & Run

Open in Xcode:

1. Open `HockeyTagger.xcodeproj`
2. Select scheme `HockeyTagger`
3. Run (`Cmd+R`)

CLI builds (from repo root):

```bash
make build-intel
make build-universal
```

## Keyboard Shortcuts

- Playback:
  - `Space`: play/pause
  - `←` / `→`: seek -/+ 2s
- Tagging:
  - `1`: Highlight
  - `2`: Goal
  - `3`: Defense
  - Tap: default clip around playhead
  - Hold: clip from key-down to key-up
- Tag Editor:
  - `D`: done
  - `Q/W`: start -/+ 0.5s
  - `A/S`: end -/+ 0.5s
  - `E`: set start to playhead
  - `F`: set end to playhead
  - `J`: jump to clip start
  - `R`: replay loop
  - `G`: share clip

## Download Video Flow

1. Menu: `Download Video...`
2. Paste HLS playlist URL (`.m3u8`)
3. Track progress in overlay
4. Cancel with button or `Esc`
5. Save with filename using save panel

## Notes

- The app is sandboxed and requires network client entitlement for remote downloads.
- Temporary files are used during download/export workflows.
