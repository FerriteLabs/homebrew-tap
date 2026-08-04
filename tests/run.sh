#!/usr/bin/env bash
# Dependency-free test runner for the homebrew-tap repository.
#
# Runs every tests/*_test.rb file with the system Ruby (minitest, stdlib
# only - no Bundler/gems required). By default the full suite runs,
# including a network-bound checksum verification against the real
# release tarball. Pass --fast (or set FERRITE_TAP_SKIP_NETWORK=1) for a
# quick offline run that skips network-bound assertions.
#
# Written to run under macOS's system /bin/bash (3.2, no mapfile/
# readarray/associative arrays) as well as any modern Bash.
#
# Usage:
#   tests/run.sh            # full suite (network required)
#   tests/run.sh --fast      # offline-friendly, skips network checks
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

for arg in "$@"; do
  case "${arg}" in
    --fast|--offline|-f)
      export FERRITE_TAP_SKIP_NETWORK=1
      ;;
    -h|--help)
      grep "^#" "$0" | sed "s/^# \{0,1\}//"
      exit 0
      ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      exit 2
      ;;
  esac
done

if ! command -v ruby >/dev/null 2>&1; then
  echo "error: ruby is required to run the test suite but was not found on PATH" >&2
  exit 1
fi

cd "${REPO_ROOT}"

# Bash 3.2 (macOS's default /bin/bash) has no mapfile/readarray builtin,
# so test files are collected into an indexed array one line at a time
# via a `while read` loop over process substitution instead.
test_files=()
while IFS= read -r test_file; do
  test_files+=("${test_file}")
done < <(find tests -maxdepth 1 -name "*_test.rb" | sort)

if [ "${#test_files[@]}" -eq 0 ]; then
  echo "error: no test files found under tests/" >&2
  exit 1
fi

echo "Running ${#test_files[@]} test file(s)$( [ "${FERRITE_TAP_SKIP_NETWORK:-0}" = "1" ] && echo " (fast/offline mode)" )..."

failures=0
for test_file in "${test_files[@]}"; do
  echo "----> ${test_file}"
  if ! ruby -I tests "${test_file}"; then
    failures=$((failures + 1))
  fi
done

echo
if [ "${failures}" -ne 0 ]; then
  echo "FAILED: ${failures} of ${#test_files[@]} test file(s) reported failures" >&2
  exit 1
fi

echo "OK: all ${#test_files[@]} test file(s) passed"
