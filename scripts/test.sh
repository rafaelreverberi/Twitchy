#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
port="${TWITCHY_TEST_PORT:-18181}"
python3 MockServer/server.py --port "$port" &
mock_pid=$!
trap 'kill "$mock_pid" 2>/dev/null || true' EXIT
for attempt in {1..30}; do
    if curl --fail --silent --output /dev/null "http://localhost:$port/v1/health"; then break; fi
    if ! kill -0 "$mock_pid" 2>/dev/null; then echo 'Mock failed to start'; exit 1; fi
    sleep 0.2
done
TWITCHY_MOCK_URL="http://localhost:$port" swift test --package-path Packages/TwitchyKit
python3 scripts/check_contract.py
