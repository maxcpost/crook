#!/bin/bash
# The one test runner. Globs sources rather than hand-listing them, excluding
# Crook/main.swift — swiftc refuses two files named main.swift in one module —
# and CrookTests/Fixtures, which holds the corpus generator, a standalone script
# with its own top-level code that must not be linked into the suite.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
SRC=$(find Crook -name '*.swift' -not -path 'Crook/Remote/Agent/*' ! -name 'main.swift' | sort)
TESTS=$(find CrookTests -name '*.swift' ! -path 'CrookTests/Fixtures/*' | sort)
xcrun swiftc -target arm64-apple-macos26.0 -O \
  $SRC $TESTS \
  -o build/crook-tests
# The remote agent is a separate program with its own top-level code, so it
# cannot be linked into the suite. Build it beside the tests and hand over the
# path: the agent tests drive the real binary over a pipe, which is exactly the
# contract `ssh host crook-agent` provides, minus the network.
if xcrun swiftc -O Crook/Remote/Agent/crook-agent.swift -o build/crook-agent; then
  export CROOK_AGENT_BIN="$PWD/build/crook-agent"
fi

exec ./build/crook-tests "$@"
