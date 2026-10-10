#!/bin/bash
# Optional, generated media for visual player verification. No remote footage.
set -euo pipefail
fixture_dir="${1:-/tmp/twitchy-visual-fixture}"
mkdir -p "$fixture_dir"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=s=640x360:r=24:d=60' \
  -f lavfi -i 'sine=frequency=440:duration=60' \
  -c:v libx264 -preset ultrafast -crf 26 -pix_fmt yuv420p -g 48 \
  -c:a aac -shortest -movflags +faststart "$fixture_dir/fixture.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$fixture_dir/fixture.mp4" \
  -c copy -hls_time 2 -hls_playlist_type vod \
  -hls_segment_filename "$fixture_dir/fixture%d.ts" "$fixture_dir/fixture.m3u8"
ffmpeg -hide_banner -loglevel error -y -i "$fixture_dir/fixture.mp4" -frames:v 1 -update 1 "$fixture_dir/fixture.png"
printf 'Visual fixture generated in %s\n' "$fixture_dir"
