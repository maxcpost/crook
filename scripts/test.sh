#!/bin/bash
# The one test runner. Globs sources rather than hand-listing them, excluding
# Crook/main.swift — swiftc refuses two files named main.swift in one module —
# and CrookTests/Fixtures, which holds the corpus generator, a standalone script
# with its own top-level code that must not be linked into the suite.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
SRC=$(find Crook -name '*.swift' ! -name 'main.swift' | sort)
TESTS=$(find CrookTests -name '*.swift' ! -path 'CrookTests/Fixtures/*' | sort)
xcrun swiftc -target arm64-apple-macos26.0 -O \
  $SRC $TESTS \
  -o build/crook-tests
exec ./build/crook-tests "$@"
