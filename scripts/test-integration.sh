#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

assert_file_contains() {
  local file="$1"
  local expected="$2"
  if ! grep -Fq -- "$expected" "$file"; then
    echo "Expected $file to contain: $expected" >&2
    echo "Actual contents:" >&2
    cat "$file" >&2
    exit 1
  fi
}

FAKE_BIN="$TEST_DIR/bin"
PROJECT_DIR="$TEST_DIR/project"
READY_FILE="$TEST_DIR/preflight-port"
REQUEST_FILE="$TEST_DIR/preflight-request.json"
ARGS_FILE="$TEST_DIR/npx-args"
CWD_FILE="$TEST_DIR/npx-cwd"
INSTALL_MARKER="$TEST_DIR/installed"
OUTPUT_FILE="$TEST_DIR/github-output"
SUMMARY_FILE="$TEST_DIR/github-summary"

mkdir -p "$FAKE_BIN" "$PROJECT_DIR/node_modules/checkly"
touch "$OUTPUT_FILE" "$SUMMARY_FILE"

cat > "$PROJECT_DIR/node_modules/checkly/package.json" <<'JSON'
{
  "name": "checkly",
  "version": "8.15.0"
}
JSON

cat > "$FAKE_BIN/npx" <<'FAKE_NPX'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$@" > "$FAKE_NPX_ARGS_FILE"
printf '%s\n' "$PWD" > "$FAKE_NPX_CWD_FILE"
printf 'Test session ID: test-session-123\n'
printf 'Open session: https://app.checklyhq.com/accounts/account-1/test-sessions/test-session-123\n'
exit "${FAKE_NPX_EXIT_CODE:-0}"
FAKE_NPX
chmod +x "$FAKE_BIN/npx"

node "$ROOT_DIR/scripts/test-preflight-server.cjs" "$READY_FILE" "$REQUEST_FILE" &
SERVER_PID="$!"

for _ in $(seq 1 100); do
  if [[ -s "$READY_FILE" ]]; then
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "Preflight test server exited before becoming ready." >&2
    exit 1
  fi
  sleep 0.05
done

if [[ ! -s "$READY_FILE" ]]; then
  echo "Preflight test server did not become ready." >&2
  exit 1
fi

preflight_port="$(cat "$READY_FILE")"
# INSTALL_MARKER is intentionally expanded by run.sh's install-command shell.
# shellcheck disable=SC2016
install_command='printf installed > "$INSTALL_MARKER"'

PATH="$FAKE_BIN:$PATH" \
CHECKLY_API_URL="http://127.0.0.1:${preflight_port}" \
CHECKLY_API_KEY=test-api-key \
CHECKLY_ACCOUNT_ID=account-1 \
GITHUB_OUTPUT="$OUTPUT_FILE" \
GITHUB_STEP_SUMMARY="$SUMMARY_FILE" \
GITHUB_REPOSITORY=checkly/checkly-action \
GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
GITHUB_RUN_ID=123456 \
GITHUB_RUN_ATTEMPT=2 \
GITHUB_WORKFLOW=Test \
GITHUB_JOB=integration \
GITHUB_EVENT_NAME=push \
GITHUB_REF=refs/heads/main \
GITHUB_SERVER_URL=https://github.com \
FAKE_NPX_ARGS_FILE="$ARGS_FILE" \
FAKE_NPX_CWD_FILE="$CWD_FILE" \
INSTALL_MARKER="$INSTALL_MARKER" \
INPUT_COMMAND=test \
INPUT_CLI_VERSION=8.15.0 \
INPUT_REPORTING=github-check \
INPUT_GITHUB_CHECK_NAME='Checkly action integration' \
INPUT_GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 \
INPUT_WORKING_DIRECTORY="$PROJECT_DIR" \
INPUT_INSTALL_COMMAND="$install_command" \
INPUT_TAGS='smoke' \
"$ROOT_DIR/scripts/run.sh"

[[ "$(cat "$CWD_FILE")" == "$PROJECT_DIR" ]]
[[ "$(cat "$INSTALL_MARKER")" == "installed" ]]
assert_file_contains "$ARGS_FILE" "--no-install"
assert_file_contains "$ARGS_FILE" "checkly"
assert_file_contains "$ARGS_FILE" "test"
assert_file_contains "$ARGS_FILE" "--detach"
assert_file_contains "$ARGS_FILE" "--tags"
assert_file_contains "$ARGS_FILE" "smoke"
assert_file_contains "$OUTPUT_FILE" "test-session-id=test-session-123"
assert_file_contains "$OUTPUT_FILE" "test-session-url=https://app.checklyhq.com/accounts/account-1/test-sessions/test-session-123"
assert_file_contains "$SUMMARY_FILE" "Test session ID: \`test-session-123\`"
assert_file_contains "$SUMMARY_FILE" "GitHub Check reporting is enabled for this run."

node - "$REQUEST_FILE" <<'NODE'
const fs = require('node:fs')
const assert = require('node:assert/strict')

const request = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
assert.equal(request.method, 'POST')
assert.equal(request.url, '/next/test-sessions/github-checks/preflight')
assert.equal(request.headers.authorization, 'Bearer test-api-key')
assert.equal(request.headers['x-checkly-account'], 'account-1')
assert.equal(request.headers['x-checkly-operator'], 'github-actions')
assert.equal(request.body.source, 'checkly-action')
assert.equal(request.body.githubCheckName, 'Checkly action integration')
assert.equal(request.body.repository, 'checkly/checkly-action')
assert.equal(request.body.sha, '0123456789abcdef0123456789abcdef01234567')
assert.equal(request.body.runId, '123456')
assert.equal(request.body.runAttempt, '2')
assert.equal(request.body.workflow, 'Test')
assert.equal(request.body.job, 'integration')
assert.equal(request.body.eventName, 'push')
NODE

cat > "$PROJECT_DIR/node_modules/checkly/package.json" <<'JSON'
{
  "name": "checkly",
  "version": "8.14.1"
}
JSON

set +e
incompatible_local_cli_output="$(
  PATH="$FAKE_BIN:$PATH" \
  INPUT_COMMAND=test \
  INPUT_CLI_VERSION=8.15.0 \
  INPUT_REPORTING=github-actions \
  INPUT_WORKING_DIRECTORY="$PROJECT_DIR" \
  "$ROOT_DIR/scripts/run.sh" 2>&1
)"
status="$?"
set -e

if [[ "$status" -eq 0 ]]; then
  echo "Expected incompatible project-local CLI to fail." >&2
  exit 1
fi
assert_file_contains <(printf '%s\n' "$incompatible_local_cli_output") "Project-local Checkly CLI 8.14.1 is older than the required 8.15.0"

cat > "$PROJECT_DIR/node_modules/checkly/package.json" <<'JSON'
{
  "name": "checkly",
  "version": "8.16.0"
}
JSON

set +e
mismatched_local_cli_output="$(
  PATH="$FAKE_BIN:$PATH" \
  INPUT_COMMAND=test \
  INPUT_CLI_VERSION=8.15.0 \
  INPUT_REPORTING=github-actions \
  INPUT_WORKING_DIRECTORY="$PROJECT_DIR" \
  "$ROOT_DIR/scripts/run.sh" 2>&1
)"
status="$?"
set -e

if [[ "$status" -eq 0 ]]; then
  echo "Expected mismatched project-local CLI to fail." >&2
  exit 1
fi
assert_file_contains <(printf '%s\n' "$mismatched_local_cli_output") "Project-local Checkly CLI 8.16.0 does not match cli-version '8.15.0'"

cat > "$PROJECT_DIR/node_modules/checkly/package.json" <<'JSON'
{
  "name": "checkly",
  "version": "8.15.0"
}
JSON

set +e
PATH="$FAKE_BIN:$PATH" \
FAKE_NPX_ARGS_FILE="$ARGS_FILE" \
FAKE_NPX_CWD_FILE="$CWD_FILE" \
FAKE_NPX_EXIT_CODE=17 \
INPUT_COMMAND=trigger \
INPUT_CLI_VERSION=8.15.0 \
INPUT_REPORTING=github-actions \
INPUT_WORKING_DIRECTORY="$PROJECT_DIR" \
"$ROOT_DIR/scripts/run.sh" >/dev/null 2>&1
status="$?"
set -e

if [[ "$status" -ne 17 ]]; then
  echo "Expected the CLI exit code 17 to propagate, got $status." >&2
  exit 1
fi

echo "All integration tests passed."
