#!/bin/bash
# Builds the tests together with the app's sources and runs them.
#
#   ./test.sh           unit tests only, no permissions needed
#   ./test.sh --live    also checks against the real window server, AX and screen capture
#                       (needs Accessibility and Screen Recording for this terminal)
#   ./test.sh --bench   also times the switcher's hot paths, before against after
#   ./test.sh --navigation
#                       really switches Spaces for about a minute, to check every switch lands
#                       on the window picked (needs two fullscreen windows of one app)
#   ./test.sh --keys    types real Cmd+Tab and Escape into the installed agent, flashing the
#                       switcher, and reports key-to-panel times from its log; ends with one
#                       quick Cmd+Tab tap, which switches to the previous window as a real one does
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/build/tests"
mkdir -p "$(dirname "$OUT")"

# Everything in src/ except main.swift, whose top-level code starts the agent.
SOURCES=()
for file in "$HERE"/src/*.swift; do
    [[ "$(basename "$file")" == "main.swift" ]] || SOURCES+=("$file")
done

swiftc -O -o "$OUT" "${SOURCES[@]}" "$HERE"/tests/*.swift \
    -framework Cocoa -framework ApplicationServices
"$OUT" "$@"
