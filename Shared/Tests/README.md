# Shared test fixtures

Binary fixtures used by both iOS and macOS test targets.

- `Fixtures/talk-canonical.mp3` is a 0.264-second mono MP3 generated with FFmpeg and verified with FFprobe. It exercises the shared bounded MPEG Layer III validator; malformed tests derive ID3-only, bogus-sync, truncated, WAV, and PCM inputs separately.
