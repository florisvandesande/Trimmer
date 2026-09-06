# Contributing to Trimmer

Trimmer is a work in progress. Bug reports, reproducible audio edge cases and focused improvements are welcome.

## Scope

The app is intended to trim the beginning and end of one audio track without re-encoding. Its compact interface, source-preserving default and simple playback controls are deliberate. Discuss changes such as effects, conversion, video support or multitrack editing in an issue before implementing them.

## Getting started

Use macOS 13 or later, Xcode 15 / Swift 5.9 or later, and an existing FFmpeg installation that provides both `ffmpeg` and `ffprobe`.

```sh
swift build
swift test
```

For a local app bundle:

```sh
bash scripts/build-app.sh
open dist/Trimmer.app
```

See the [technical notes](docs/technical-notes.md) for the structure and processing details.

## Reporting a bug

Include the macOS version, Mac architecture, FFmpeg version, steps to reproduce, and what you expected to happen. For audio issues, include the container, codec and approximate cut positions. A small, non-sensitive sample that you have permission to share is helpful. Remove personal file paths and private metadata from logs before posting them publicly.

For visual issues, include the window size and a screenshot when possible. The interface is currently in Dutch; reports in Dutch or English are welcome.

## Pull requests

Keep each change focused and explain the resulting behavior. For audio processing changes, run the integration tests with FFmpeg installed; skipped tests do not validate stream-copy integrity. Add a regression test for a reproduced bug when it meaningfully protects the behavior. For interface changes, check the native app at its compact size, including long filenames and saved/exporting states.

Do not commit build output, generated test audio, local app bundles or credentials. Screenshots used in documentation belong in `docs/screenshots` with descriptive filenames.

The built-in dependency installer is not yet validated. Do not remove or replace a working Homebrew installation merely to test it; use a separate test environment for that work.
