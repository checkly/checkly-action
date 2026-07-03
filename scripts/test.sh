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

assert_fails_with() {
  local expected="$1"
  shift
  local output
  set +e
  output="$("$@" 2>&1)"
  local status="$?"
  set -e
  if [[ "$status" -eq 0 ]]; then
    echo "Expected command to fail." >&2
    echo "Actual output:" >&2
    echo "$output" >&2
    exit 1
  fi
  assert_contains "$output" "$expected"
}

test_command_output="$(
  INPUT_COMMAND=test \
  INPUT_CLI_VERSION=8.12.0 \
  CHECKLY_ACTION_GITHUB_REPORT_AVAILABLE=true \
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
assert_contains "$test_command_output" "checkly@8.12.0 test --detach"
assert_contains "$test_command_output" "--tags production\\,webapp --tags production\\,backend"
assert_contains "$test_command_output" "--grep checkout"
assert_contains "$test_command_output" "--update-snapshots"
assert_contains "$test_command_output" "checks/\\*\\*/\\*.check.ts smoke.check.ts"
assert_contains "$test_command_output" "GitHub report: detached writeback enabled"

trigger_command_output="$(
  INPUT_COMMAND=trigger \
  INPUT_CLI_VERSION=latest \
  CHECKLY_ACTION_GITHUB_REPORT_AVAILABLE=true \
  INPUT_TAGS='production' \
  INPUT_CHECK_ID='abc,def' \
  INPUT_FAIL_ON_NO_MATCHING=false \
  run_dry
)"

assert_contains "$trigger_command_output" "checkly@latest trigger --detach"
assert_contains "$trigger_command_output" "--tags production"
assert_contains "$trigger_command_output" "--check-id abc\\,def"
assert_contains "$trigger_command_output" "--no-fail-on-no-matching"

fallback_command_output="$(
  INPUT_COMMAND=test \
  INPUT_CLI_VERSION=8.12.0 \
  CHECKLY_ACTION_GITHUB_REPORT_AVAILABLE=false \
  CHECKLY_ACTION_GITHUB_REPORT_REASON=github_app_not_connected \
  GITHUB_ACTIONS=true \
  run_dry
)"

assert_contains "$fallback_command_output" "checkly@8.12.0 test --reporter=github"
assert_contains "$fallback_command_output" "GitHub report: unavailable (github_app_not_connected), waiting for CLI result"

assert_fails_with "github-report requires Checkly CLI 8.12.0 or newer" env \
  INPUT_COMMAND=test \
  INPUT_CLI_VERSION=8.11.9 \
  INPUT_GITHUB_REPORT=true \
  CHECKLY_ACTION_GITHUB_REPORT_AVAILABLE=true \
  CHECKLY_ACTION_DRY_RUN=1 \
  "$ROOT_DIR/scripts/run.sh"

prerelease_version_output="$(
  INPUT_COMMAND=test \
  INPUT_CLI_VERSION=0.0.0-canary.58c867e \
  INPUT_GITHUB_REPORT=true \
  CHECKLY_ACTION_GITHUB_REPORT_AVAILABLE=true \
  run_dry
)"

assert_contains "$prerelease_version_output" "checkly@0.0.0-canary.58c867e test --detach"

github_event_path="$(mktemp)"
trap 'rm -f "$github_event_path"' EXIT
cat > "$github_event_path" <<'JSON'
{
  "pull_request": {
    "head": {
      "sha": "head123def456",
      "repo": {
        "full_name": "checkly/playwright-reporter-demo"
      }
    }
  }
}
JSON

github_report_output="$(
  INPUT_COMMAND=test \
  INPUT_GITHUB_REPORT=true \
  CHECKLY_ACTION_GITHUB_REPORT_AVAILABLE=true \
  GITHUB_REPOSITORY=checkly/playwright-reporter-demo \
  GITHUB_SHA=merge123def456 \
  GITHUB_RUN_ID=123456 \
  GITHUB_RUN_ATTEMPT=2 \
  GITHUB_WORKFLOW=Checkly \
  GITHUB_JOB=validate \
  GITHUB_EVENT_NAME=pull_request \
  GITHUB_EVENT_PATH="$github_event_path" \
  GITHUB_REF=refs/pull/4/merge \
  GITHUB_REF_NAME=4/merge \
  GITHUB_HEAD_REF=herve/test-checkly-action \
  GITHUB_BASE_REF=main \
  GITHUB_SERVER_URL=https://github.com \
  run_dry
)"

assert_contains "$github_report_output" "GitHub report: detached writeback enabled for checkly/playwright-reporter-demo@head123def456"

github_report_disabled_output="$(
  INPUT_COMMAND=test \
  INPUT_CLI_VERSION=8.11.9 \
  INPUT_GITHUB_REPORT=false \
  CHECKLY_GITHUB_REPORT=true \
  CHECKLY_GITHUB_REPOSITORY=spoofed/repository \
  CHECKLY_GITHUB_SHA=spoofed-sha \
  GITHUB_REPOSITORY=checkly/playwright-reporter-demo \
  GITHUB_SHA=abc123def456 \
  run_dry
)"

assert_contains "$github_report_disabled_output" "GitHub report: disabled"
assert_contains "$github_report_disabled_output" "checkly@8.11.9 test --reporter=github"

deployment_event_path="$(mktemp)"
trap 'rm -f "$github_event_path" "$deployment_event_path"' EXIT
cat > "$deployment_event_path" <<'JSON'
{
  "deployment_status": {
    "environment_url": "https://preview.example.com"
  }
}
JSON

deployment_url_output="$(
  INPUT_COMMAND=test \
  INPUT_GITHUB_REPORT=false \
  GITHUB_EVENT_NAME=deployment_status \
  GITHUB_EVENT_PATH="$deployment_event_path" \
  run_dry
)"

assert_contains "$deployment_url_output" "Environment URL: https://preview.example.com"

echo "All local action tests passed."
