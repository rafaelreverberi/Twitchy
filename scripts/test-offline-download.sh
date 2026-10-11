#!/bin/bash
# Exercise real FFmpeg 5.1.9 delay_moov bytes through the client, never user storage.
set -euo pipefail
cd "$(dirname "$0")/.."
fixture="${1:-audio}"
case "$fixture" in
  audio) filename=clip-audio-true.mp4 ;;
  video-only) filename=clip-audio-false.mp4 ;;
  *) echo 'Usage: test-offline-download.sh [audio|video-only]' >&2; exit 2 ;;
esac
media_dir=$(mktemp -d "${TMPDIR:-/tmp}/twitchy-offline.XXXXXX")
mock_pid=''
cleanup() {
    if [[ -n "$mock_pid" ]]; then
        kill "$mock_pid" 2>/dev/null || true
        wait "$mock_pid" 2>/dev/null || true
    fi
    rm -rf "$media_dir"
}
trap cleanup EXIT
cp MockServer/media/* "$media_dir/"
cp "Packages/TwitchyKit/Tests/TwitchyKitTests/Fixtures/$filename" "$media_dir/fixture.mp4"
port="${TWITCHY_TEST_PORT:-18183}"
python3 MockServer/server.py --port "$port" --media-dir "$media_dir" &
mock_pid=$!
for attempt in {1..30}; do
    if ! kill -0 "$mock_pid" 2>/dev/null; then echo 'Mock failed to start' >&2; exit 1; fi
    if curl --fail --silent --output /dev/null "http://localhost:$port/v1/health"; then break; fi
    sleep 0.2
done
TWITCHY_MOCK_URL="http://localhost:$port" TWITCHY_DELAY_MOOV_INTEGRATION="$fixture" \
    swift test --package-path Packages/TwitchyKit --filter 'Offline|DelayMoov|delayMoov|editList|audioPriming|versionOne|mockDownloadTransfer|mockRetryFailed'
