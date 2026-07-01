#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_dry() {
  CHECKLY_ACTION_DRY_RUN=1 "$ROOT_DIR/scripts/run.sh"
}

assert_contains() {
  local output="$1"
  local expected="$2"
  if [[ "$output" != *"$expected"* ]]; then
    echo "Expected output to contain: $expected" >&2
    echo "Actual output:" >&2
    echo "$output" >&2
    exit 1
  fi
}

test_command_output="$(
  INPUT_COMMAND=test \
  INPUT_CLI_VERSION=1.2.3 \
  INPUT_TAGS=$'production,webapp\nproduction,backend' \
  INPUT_GREP='checkout' \
  INPUT_FILES=$'checks/**/*.check.ts\nsmoke.check.ts' \
  INPUT_CONFIG='checkly.config.ts' \
  INPUT_REFRESH_CACHE=true \
  INPUT_UPDATE_SNAPSHOTS=true \
  run_dry
)"

assert_contains "$test_command_output" "checkly@1.2.3 test --detach"
assert_contains "$test_command_output" "--tags production\\,webapp --tags production\\,backend"
assert_contains "$test_command_output" "--grep checkout"
assert_contains "$test_command_output" "--update-snapshots"
assert_contains "$test_command_output" "checks/\\*\\*/\\*.check.ts smoke.check.ts"

trigger_command_output="$(
  INPUT_COMMAND=trigger \
  INPUT_CLI_VERSION=latest \
  INPUT_TAGS='production' \
  INPUT_CHECK_ID='abc,def' \
  INPUT_FAIL_ON_NO_MATCHING=false \
  run_dry
)"

assert_contains "$trigger_command_output" "checkly@latest trigger --detach"
assert_contains "$trigger_command_output" "--tags production"
assert_contains "$trigger_command_output" "--check-id abc\\,def"
assert_contains "$trigger_command_output" "--no-fail-on-no-matching"

echo "All local action tests passed."
