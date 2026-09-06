# Technical notes

## Project structure

| Location | Responsibility |
| --- | --- |
| `Sources/Trimmer` | SwiftUI interface, playback, editor state and dependency setup |
| `Sources/TrimmerCore` | FFmpeg execution, file inspection, waveform processing and export |
| `Tests/TrimmerTests` | Trim handle and playhead behavior |
| `Tests/TrimmerCoreTests` | Audio integrity and file processing |
| `scripts/build-app.sh` | Release build, app bundle, icon and local signing |

The app targets macOS 13 or later and uses SwiftUI, AppKit and AVFoundation. Open `Package.swift` in Xcode or use the Swift package command line tools.

## Stream copy and saving

FFprobe supplies the audio stream information and packet timestamps. Trim positions are aligned with those timestamps. Export uses FFmpeg’s `-c copy`, with no audio filters or encoding stage. A second copy-only mux preserves embedded artwork when necessary.

The destination keeps the source extension. Export is first written to a temporary directory beside the destination. The app checks the output stream’s codec, sample rate and channel count before committing it. Explicit replacements use a same-filesystem rename; new files are moved without silently overwriting another file.

These runtime checks are not a full audio integrity comparison. Integration tests separately compare packet payloads or decoded samples for the tested formats. Metadata, container headers and timestamps may change even though the encoded audio content is preserved.

## Native FLAC

Native FLAC stores frame or sample positions inside each frame, as well as the original sample count in STREAMINFO. FFmpeg stream copy alone can leave these values describing the original file.

`FLACRepair` updates the frame numbering, header and frame checksums, frame size information and total sample count. Compressed audio subframes are copied unchanged. Seek tables and cue information are removed. The original MD5 is cleared to the format’s “unknown” value because it no longer describes the shortened recording.

The framing follows the [FLAC specification, RFC 9639](https://www.rfc-editor.org/rfc/rfc9639.html).

## Playback and waveform

AVAudioPlayer handles playback. If it cannot open the source directly, FFmpeg creates a temporary decoded CAF preview. This preview is never used for export.

Waveform generation decodes the source to temporary floating-point audio at 8 kHz, then reduces it to at most 24,000 peak values. It takes absolute peaks across all channels so opposite-phase stereo channels do not cancel out. File inspection and audio processing run outside the main actor.

The app removes its temporary workspace when switching files or closing normally. A forced termination may leave temporary files for the operating system to clean up.

## Trim interaction

A deliberate seek or successful playback marks the playhead as positioned. Moving either trim handle then preserves that position, even if the new selection excludes it. Dragging pauses playback. Within six logical screen points, the handle snaps to the nearest legal packet boundary at the playhead, provided the selection remains nonempty.

A playhead that has not been positioned follows the handle. Seeking to zero or resetting the selection restores that behavior. Handle-driven movement does not count as a deliberate seek. Keyboard and accessibility trim adjustments use packet snapping without the pointer’s magnetic range.

## Dependencies

Trimmer looks for both `ffmpeg` and `ffprobe` in `/opt/homebrew/bin`, `/usr/local/bin` and its inherited `PATH`, and verifies that they run. It does not need changes to shell configuration files.

When either tool is missing, the app offers a dependency installation flow with an indeterminate progress bar and a log. If Homebrew is absent, it downloads the [official Homebrew installer](https://docs.brew.sh/Installation) over HTTPS and opens it in Terminal for its normal confirmations, administrator authentication and developer-tool setup. Trimmer does not collect or store the administrator password. It then runs `brew install ffmpeg` as the regular user and checks both executables again.

**This installation flow has not yet been validated.** The current version was tested with an existing FFmpeg 8.1 installation. Homebrew’s own operating system and hardware support requirements are separate from Trimmer’s macOS 13 deployment target.

## Local visual checks

A debug build can render its actual native window to a PNG:

```sh
swift run Trimmer --snapshot /tmp/trimmer.png --preview-file /path/to/audio.wav
```

Omit `--preview-file` to capture the welcome screen. The command does not alter the source audio and is not available in release builds.
