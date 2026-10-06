# Audio analysis and multiwindow validation

Validated on macOS / Apple Silicon, 2026-10-05.

## Automated coverage

`swift test` covers packet-preserving export, malformed/unsupported inputs,
waveform range maxima, copied passages with volume changes, multiple repetitions,
faded transitions, silence, unrelated noise, minimum duration, cancellation,
zoom anchoring and bounds, magnetic trim boundaries, saved-selection baselines,
independent editors, persistent settings, and sequential quit decisions.

The optional local acceptance test reads `TRIMMER_TEST_AUDIO`. No user audio or
absolute user path is part of the repository. With Angels supplied, it confirms a
repeat near the end without embedding that timestamp in the detector.

## Measurements

Optimized builds, three sequential runs against a 626.178-second stereo ALAC file
(Angels). Times are seconds from the start of opening; dependencies were already
available. These measure the processing pipeline, not launch-to-screen latency.

| Milestone | Previous pipeline, mean | New pipeline, mean |
| --- | ---: | ---: |
| Metadata available | 0.357 (after packet indexing) | 0.176 |
| Native playback prepared | 0.361 | 0.180 |
| First waveform | 0.894 | 0.284 |
| Complete waveform | 0.894 | 0.669 |
| Repeat detection complete | Not available | 0.676 |

The detected repeated interval is 531.3–626.1 seconds; its reference interval is
1.4–96.2 seconds. Detection marks confirmed matching content, so a transition can
start earlier than the highlighted interval. Boundaries remain advisory and snap
to valid packet boundaries when used for trimming.

Reproduce the new measurements:

```sh
swiftc -O -parse-as-library Sources/TrimmerCore/*.swift scripts/benchmark-analysis.swift -o /tmp/trimmer-benchmark
/tmp/trimmer-benchmark /absolute/path/to/audio
```

The benchmark requires a natively playable file. The editor additionally supports
FFmpeg playback fallback for other supported formats.

## Native checks

- Angels opens with distinct original/repetition shading.
- Zoom menus change the visible range while retaining selection times; waveform
  and trim graphics stay clipped to their viewport.
- Accessibility page scrolling moves the visible time range and its trim overlay together.
- Opening another file creates a separate editor.
- CMD+W prompts for a changed selection; cancellation preserves it.
- Restoring an untouched baseline and closing does not prompt.
- Closing a successfully saved selection does not prompt.
- CMD+Q asks separately for two modified files. Saving the first and cancelling
  the second leaves both editors open and retains the completed export.
- The saved ALAC test export retains two channels.
- Settings reject zero and provide an explicit Save action.

Physical trackpad pinch and smooth two-finger scrolling require hands-on
confirmation; the automated interaction tool does not expose a pinch gesture and
its generic scroll command did not produce an observable event in this custom
view. Accessibility page scrolling was verified separately. Zoom anchoring and
clamping are covered by model tests.

## Settings and endpoint follow-up

- Replaced the macOS Form with centered controls on the editor's dark background,
  using its yellow accent and button style. The duration field has no visible
  label duplicate. The scope text reads “Geldt voor alle audio bestanden.”
- Recognition has a persistent, immediately applied switch (default on for
  existing installations). Turning it off cancels detection and clears regions
  and their magnetic boundaries in all open editors. Turning it on reuses the
  cached analysis. Future editors inherit the saved preference.
- Added coverage for preference persistence, three concurrent editors, rapid
  toggles, and rejection of late results after disabling recognition.
- Endpoint coordinate rounding previously hid the handle in 39 of 128 regression
  scenarios. The mapping now snaps sub-micro-point numerical error to the exact
  viewport edge, without exposing genuinely offscreen handles.
- Native verification with Ocean Shore: open untouched, zoom to 4x, navigate to
  the end. The endpoint handle is visible and dragging it changes the selection
  from 10:30.163 to 10:16.960. The test selection was reset; no source audio was
  overwritten. Enabling recognition restores the highlights without reopening.
- All 33 automated tests passed, including the optional Angels acceptance test.
  The release app builds and passes strict code-sign verification.
