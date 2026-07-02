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
  INPUT_INSTALL_COMMAND='npm ci' \
  INPUT_REFRESH_CACHE=true \
  INPUT_UPDATE_SNAPSHOTS=true \
  run_dry
)"

assert_contains "$test_command_output" "Install command: npm ci"
assert_contains "$test_command_output" "checkly@1.2.3 test --detach"
assert_contains "$test_command_output" "--tags production\\,webapp --tags production\\,backend"
assert_contains "$test_command_output" "--grep checkout"
assert_contains "$test_command_output" "--update-snapshots"
assert_contains "$test_command_output" "checks/\\*\\*/\\*.check.ts smoke.check.ts"
assert_contains "$test_command_output" "GitHub report: enabled"

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

github_report_output="$(
  INPUT_COMMAND=test \
  INPUT_GITHUB_REPORT=true \
  GITHUB_REPOSITORY=checkly/playwright-reporter-demo \
  GITHUB_SHA=abc123def456 \
  GITHUB_RUN_ID=123456 \
  GITHUB_RUN_ATTEMPT=2 \
  GITHUB_WORKFLOW=Checkly \
  GITHUB_JOB=validate \
  GITHUB_EVENT_NAME=pull_request \
  GITHUB_REF=refs/pull/4/merge \
  GITHUB_REF_NAME=4/merge \
  GITHUB_HEAD_REF=herve/test-checkly-action \
  GITHUB_BASE_REF=main \
  GITHUB_SERVER_URL=https://github.com \
  run_dry
)"

assert_contains "$github_report_output" "GitHub report: enabled for checkly/playwright-reporter-demo@abc123def456"

github_report_disabled_output="$(
  INPUT_COMMAND=test \
  INPUT_GITHUB_REPORT=false \
  CHECKLY_GITHUB_REPORT=true \
  CHECKLY_GITHUB_REPOSITORY=spoofed/repository \
  CHECKLY_GITHUB_SHA=spoofed-sha \
  GITHUB_REPOSITORY=checkly/playwright-reporter-demo \
  GITHUB_SHA=abc123def456 \
  run_dry
)"

assert_contains "$github_report_disabled_output" "GitHub report: disabled"

echo "All local action tests passed."
