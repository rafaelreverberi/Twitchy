# Offline download indexing correction

Locally verified on 2026-10-11; no push, release or deployment.

## Cause

The unchanged `OfflineMP4.prepare` rejected all four actual corrected-server FFmpeg 5.1.9 fixtures, including video-only clips/VODs. Instrumentation at the replacement-file validation identified the precise failure: AVFoundation loaded **0.08 seconds** from the indexed file, versus sample-derived expectations of 6.000 seconds (video only) / 6.038 seconds (AAC). The replacement was rejected before `replaceItemAt`; the temporary indexed file was discarded, leaving the input intact. DownloadManager subsequently treats this error as failure and deletes its failed transfer.

`delay_moov` includes an edit list ending in a zero-duration media segment. That open segment works in the original fragmented movie. When the client converts it to regular sample tables, copying the edit unchanged leaves only the preceding 80 ms empty video edit on the AVFoundation timeline. The original 30-second BastiGHG transfer is already deleted, so this establishes the mechanism on the supplied real server output, not a byte-level diagnosis of that unavailable transfer. There is no evidence here of a transfer interruption.

## Correction and timing audit

Only the shared offline MP4 indexer changes in production. It fills an open final media edit using the last presentation end minus `media_time`, converting track ticks to movie ticks with upward rounding. It retains empty edits, finite edit durations, `media_time` (including priming/trim), media rates of 1 and edit-list version 0/1. Other rates or malformed open edits are rejected. `tkhd` and `mvhd` now use the resulting edit timeline; `mdhd` retains the sample-derived media duration. There is no transcode or fabricated AAC configuration.

For the original fixture, `mvhd` timescale is 1000, video `mdhd` 90000 and audio `mdhd` 48000. Video media time 7200 is 80 ms; it removes the decoding/composition lead-in, while the empty 80-tick movie edit restores the intended start. Audio's 58-tick empty edit retains its separate 58 ms start; its media time is zero. New segment durations are 6000 movie ticks for video and 6038 for audio. These values are derived, not hard-coded. A doubled movie-timescale test proves the conversion; a one-AAC-frame (1024 track ticks) trim removes exactly 1024 decoded frames while preserving the offset.

Sample offsets remain checked against bounded `mdat` ranges. The fixture has zero `trex` defaults, with real size/duration/flags supplied by `tfhd` and per-sample `trun` fields. Video decode ticks are 3600 per frame, AAC ticks 1024 per frame; all `tfdt` sequences start at zero and are contiguous. The indexer now checks that continuity rather than silently collapsing a gap/overlap. Nonzero initial decode times or discontinuous fragments are rejected; rebasing such inputs is outside this correction. Unsigned `trun` composition offsets must fit the signed `ctts` representation, while version-1 signed offsets retain their meaning. Metadata and sample-count limits remain in place.

Replacement duration, expected content duration, playability and cancellation are checked before replacing the original. Expected-duration tolerances are unchanged. A second prepare call leaves the prepared file byte-identical. DownloadManager, authentication, streaming, app UI and tvOS-specific behavior are unchanged.

## Verification

- Four supplied clip/VOD fixtures with/without AAC: complete post-index AVFoundation decoding, duration 6.08 s, final video image at 6.04 s, and repeat-prepare byte equality passed. AVFoundation fills the empty edit with one image at time zero (151 output images for 150 encoded video frames).
- AAC-LC metadata is 48 kHz stereo. AVFoundation decoded 292576 PCM frames including the initial empty-edit silence, through 6.095333 s, with tone RMS between 0.02 and 0.2 in every second from 0–6. The end differs from video's 6.08 s by about 15 ms. The independent priming test decodes 291552 frames, ending at 6.074 s.
- FFmpeg full decoded-stream SHA-256 matches before/after indexing: video `eddf030182329fb7976d06c408fd4d0c3251dab2cf0da1694b0d47d174f0daa9`, audio `9c5c2613d346aabc5b6e0b72bf591a33c845073a14d3d6bfa031404e04793f65`. ffprobe still reports starts 0.080 s / 0.058 s and two-byte AAC extradata. Media samples and AAC configuration survive the client conversion.
- Truncated real fixtures, invalid sample offsets, inconsistent `tfdt`, unsupported edit rate and an expected 30-second duration on a six-second movie are rejected with byte-identical original files. Finite edits, version-1 edit lists, another movie timescale, AAC priming and the earlier eight-second no-edit fixture pass.
- Local HTTP fixture → URLSessionDownloadTask → OfflineMP4.prepare → completed index → new DownloadManager instance → PlaybackController.startOffline → AVPlayer playback through at least 5.9 s → delete: passed for both clip and VOD. Audio and video-only fixture runs are reproducible with the script below. The ordinary MP4 mock tests cover the previously working nonfragmented path.
- Final full package runs: **67 tests passed** with the ordinary MP4/HLS mock, and **67 tests passed** with the real AAC download fixture. Dedicated audio/video-only script runs each passed **16 tests**, including parameterized clip/VOD persistence and native playback. No failures in these final runs. Real-account/recorded-media opt-in tests remain skipped.
- macOS and iOS Simulator application builds with Swift 6 strict concurrency passed. The existing iOS UI regression downloaded the real AAC fixture, opened Downloads → Play offline in the normal mounted player, reached playing, entered/exited fullscreen and retained offline chat without creating a streaming session. Device: iPhone 18 Pro, iOS 27.0 Simulator.

Run `scripts/test-offline-download.sh audio` and `scripts/test-offline-download.sh video-only`. Each serves a test copy from a temporary directory and gives DownloadManager separate temporary storage. `scripts/test.sh` exercises the ordinary MP4/HLS mocks; `scripts/build.sh` runs the full package suite, platform builds and contract check. For the iOS UI test, serve a temporary media directory containing the real fixture as `fixture.mp4` on port 8181 and run `NavigationTests/testOfflineDownloadUsesTheNormalPlayerAndOfflineChat` in the Twitchy-iOS scheme.

The expanded full-decode test workload initially blocked the Swift cooperative executor when many synchronous AVAssetReaders ran together. The test-only decoder helper now runs on the main actor, serializing its blocking reads; the final complete reruns passed.

Raw local logs are in `.build/offline-regression/` (ignored by Git). Fixture provenance/hashes are in the test resource `Fixtures/DELAY_MOOV.md`.

## Boundaries

No real Twitch account/download, physical iPhone or production server was used. macOS checks include actual AVFoundation decode and AVPlayer playback, not a manual tour of the desktop app. The iOS simulator checks the real transfer/indexing/UI playback path; the detailed full-track PCM and image assertions ran on macOS. No existing user downloads were modified. Deleted/failed downloads are not automatically restored; retry them with the corrected client/server.
