#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

FAKE_BIN="$TEST_DIR/bin"
GH_LOG="$TEST_DIR/gh-calls"
SLEEP_LOG="$TEST_DIR/sleep-calls"
ROUTES_FILE="$TEST_DIR/gh-routes.json"
OUTPUT_FILE="$TEST_DIR/github-output"
STEP_SCRIPT="$TEST_DIR/step.sh"
mkdir -p "$FAKE_BIN"

REPOSITORY=checkly/monorepo
RUN_ID=40862056136
JOB_ID=123394345920
LATEST_JOB_ID=123407491960
SHA=0123456789abcdef0123456789abcdef01234567
JOB_NAME="e2e/webapp dispatch"
RUN_URL="https://github.com/checkly/monorepo/actions/runs/${RUN_ID}"

# Answers `gh api` from a routes file that maps "METHOD endpoint" to a list of
# responses. Each call takes the next response and the last one repeats.
cat > "$FAKE_BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -Eeuo pipefail
method=GET
filter=""
endpoint=""
[[ "${1:-}" == "api" ]] && shift
while (($#)); do
  case "$1" in
    --method|-X) method="$2"; shift 2 ;;
    --jq|-q) filter="$2"; shift 2 ;;
    --paginate) shift ;;
    *) endpoint="$1"; shift ;;
  esac
done
key="$method $endpoint"
printf '%s\n' "$key" >> "$FAKE_GH_LOG"
call="$(grep -cxF -- "$key" "$FAKE_GH_LOG")"
response="$(jq -c --arg key "$key" --argjson call "$call" \
  '(.[$key] // [{"status": 404, "body": {"message": "Not Found"}}]) | .[([$call, length] | min) - 1]' "$FAKE_GH_ROUTES")"
status="$(jq -r '.status // 200' <<< "$response")"
if (( status >= 400 )); then
  jq -c '.body' <<< "$response"
  printf 'gh: %s (HTTP %s)\n' "$(jq -r '.body.message' <<< "$response")" "$status" >&2
  exit 1
fi
if [[ -n "$filter" ]]; then
  jq -r "$filter" <<< "$(jq -c '.body' <<< "$response")"
else
  jq -c '.body // {}' <<< "$response"
fi
FAKE_GH
chmod +x "$FAKE_BIN/gh"

cat > "$FAKE_BIN/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >> "$FAKE_SLEEP_LOG"
FAKE_SLEEP
chmod +x "$FAKE_BIN/sleep"

# The runner substitutes the composite step's run line into a script.
sed -nE 's/^[[:space:]]+run:[[:space:]]+//p' "$ROOT_DIR/rerun/action.yml" \
  | sed "s|\${{ github.action_path }}|$ROOT_DIR/rerun|g" > "$STEP_SCRIPT"

default_routes="$(
  jq -n \
    --arg repository "$REPOSITORY" \
    --argjson run_id "$RUN_ID" \
    --argjson job_id "$JOB_ID" \
    --argjson latest_job_id "$LATEST_JOB_ID" \
    --arg sha "$SHA" \
    --arg name "$JOB_NAME" \
    --arg run_url "$RUN_URL" \
    '{
      "GET repos/\($repository)/actions/jobs/\($job_id)": [{ body: { id: $job_id, run_id: $run_id, head_sha: $sha, name: $name } }],
      "GET repos/\($repository)/actions/runs/\($run_id)": [{ body: { status: "completed", html_url: $run_url } }],
      "GET repos/\($repository)/actions/runs/\($run_id)/jobs?filter=latest&per_page=100": [{ body: { jobs: [
        { id: 1, status: "completed", name: "Lint" },
        { id: $latest_job_id, status: "completed", name: $name }
      ] } }],
      "POST repos/\($repository)/actions/jobs/\($latest_job_id)/rerun": [{ status: 201, body: {} }]
    }'
)"

# Merges route overrides, written with the shell variables above, into the
# default routes.
write_routes() {
  local overrides="${1:-}"
  jq -n --argjson defaults "$default_routes" --argjson overrides "${overrides:-null}" '$defaults + ($overrides // {})' > "$ROUTES_FILE"
}

run_step() {
  : > "$GH_LOG"
  : > "$SLEEP_LOG"
  : > "$OUTPUT_FILE"
  set +e
  step_output="$(
    PATH="$FAKE_BIN:$PATH" \
    GH_TOKEN=test-github-token \
    GITHUB_OUTPUT="$OUTPUT_FILE" \
    GITHUB_REPOSITORY="$REPOSITORY" \
    GITHUB_EVENT_NAME=repository_dispatch \
    CHECKLY_RERUN_EVENT_TYPE=checkly-github-check-rerun \
    CHECKLY_RERUN_VERSION=1 \
    CHECKLY_RERUN_REPOSITORY="$REPOSITORY" \
    CHECKLY_RERUN_SHA="$SHA" \
    CHECKLY_RERUN_RUN_ID="$RUN_ID" \
    CHECKLY_RERUN_JOB_ID="$JOB_ID" \
    FAKE_GH_LOG="$GH_LOG" \
    FAKE_GH_ROUTES="$ROUTES_FILE" \
    FAKE_SLEEP_LOG="$SLEEP_LOG" \
    env "$@" bash -e "$STEP_SCRIPT" 2>&1
  )"
  step_status="$?"
  set -e
}

fail_test() {
  echo "$1" >&2
  echo "Step output:" >&2
  echo "$step_output" >&2
  exit 1
}

assert_succeeded() {
  [[ "$step_status" -eq 0 ]] || fail_test "Expected the step to succeed, got exit $step_status."
}

assert_failed_with() {
  [[ "$step_status" -ne 0 ]] || fail_test "Expected the step to fail."
  [[ "$step_output" == *"::error::$1"* ]] || fail_test "Expected the error: $1"
  if grep -q '^POST ' "$GH_LOG"; then
    fail_test "Expected no re-run request."
  fi
}

assert_file_lines() {
  local file="$1"
  local expected="$2"
  local actual
  actual="$(cat "$file")"
  [[ "$actual" == "$expected" ]] || fail_test "Expected $file to be:"$'\n'"$expected"$'\n'"Actual:"$'\n'"$actual"
}

assert_no_api_calls() {
  [[ ! -s "$GH_LOG" ]] || fail_test "Expected no GitHub API call."
}

# A click on a check from attempt 1 re-runs the same-named job of the latest attempt.
write_routes
run_step
assert_succeeded
assert_file_lines "$GH_LOG" "GET repos/${REPOSITORY}/actions/jobs/${JOB_ID}
GET repos/${REPOSITORY}/actions/runs/${RUN_ID}
GET repos/${REPOSITORY}/actions/runs/${RUN_ID}/jobs?filter=latest&per_page=100
POST repos/${REPOSITORY}/actions/jobs/${LATEST_JOB_ID}/rerun"
assert_file_lines "$OUTPUT_FILE" "run-url=${RUN_URL}
job-id=${LATEST_JOB_ID}"
[[ "$step_output" == *"::notice::Re-running job ${JOB_NAME} (${LATEST_JOB_ID}) of run ${RUN_URL}"* ]] || fail_test "Expected the re-run notice."
[[ ! -s "$SLEEP_LOG" ]] || fail_test "Expected no wait for a completed run."

# When the payload's job is itself in the latest attempt, that exact job is re-run.
write_routes "$(jq -n --arg key "GET repos/${REPOSITORY}/actions/runs/${RUN_ID}/jobs?filter=latest&per_page=100" \
  --argjson job_id "$JOB_ID" --argjson latest_job_id "$LATEST_JOB_ID" --arg name "$JOB_NAME" \
  '{ ($key): [{ body: { jobs: [{ id: $latest_job_id, status: "completed", name: $name }, { id: $job_id, status: "completed", name: $name }] } }],
     ("POST repos/checkly/monorepo/actions/jobs/\($job_id)/rerun"): [{ status: 201, body: {} }] }')"
run_step
assert_succeeded
[[ "$(tail -n 1 "$GH_LOG")" == "POST repos/${REPOSITORY}/actions/jobs/${JOB_ID}/rerun" ]] || fail_test "Expected the payload's job to be re-run."

# A run that finishes while the handler waits is re-run after the wait.
write_routes "$(jq -n --arg key "GET repos/${REPOSITORY}/actions/runs/${RUN_ID}" --arg run_url "$RUN_URL" \
  '{ ($key): [{ body: { status: "in_progress", html_url: $run_url } }, { body: { status: "queued", html_url: $run_url } }, { body: { status: "completed", html_url: $run_url } }] }')"
run_step
assert_succeeded
assert_file_lines "$SLEEP_LOG" "sleep 30
sleep 30"
[[ "$(tail -n 1 "$GH_LOG")" == "POST repos/${REPOSITORY}/actions/jobs/${LATEST_JOB_ID}/rerun" ]] || fail_test "Expected the job to be re-run."

# A run that is still in progress after three retries fails without re-running.
write_routes "$(jq -n --arg key "GET repos/${REPOSITORY}/actions/runs/${RUN_ID}" --arg run_url "$RUN_URL" \
  '{ ($key): [{ body: { status: "in_progress", html_url: $run_url } }] }')"
run_step
assert_failed_with "Run ${RUN_ID} is still in progress. Re-run the job from the Actions tab once the run has finished."
assert_file_lines "$SLEEP_LOG" "sleep 30
sleep 30
sleep 30"
[[ "$(grep -cxF "GET repos/${REPOSITORY}/actions/runs/${RUN_ID}" "$GH_LOG")" -eq 4 ]] || fail_test "Expected four run status reads."

# Every payload check fails before any GitHub API call.
write_routes
run_step GITHUB_EVENT_NAME=workflow_dispatch
assert_failed_with "The Checkly re-run action handles repository_dispatch events only. This workflow ran for workflow_dispatch."
assert_no_api_calls

run_step CHECKLY_RERUN_EVENT_TYPE=preview-ready
assert_failed_with "The repository_dispatch event type is not checkly-github-check-rerun."
assert_no_api_calls

run_step CHECKLY_RERUN_VERSION=2
assert_failed_with "The re-run payload version is not supported. This action handles version 1."
assert_no_api_calls

run_step CHECKLY_RERUN_REPOSITORY=checkly/other
assert_failed_with "The re-run payload does not name this workflow's repository (${REPOSITORY})."
assert_no_api_calls

run_step GITHUB_REPOSITORY= CHECKLY_RERUN_REPOSITORY=
assert_failed_with "The re-run payload does not name this workflow's repository."
assert_no_api_calls

run_step CHECKLY_RERUN_RUN_ID="1; touch $TEST_DIR/injected"
assert_failed_with "The re-run payload has no valid run_id."
assert_no_api_calls
[[ ! -e "$TEST_DIR/injected" ]] || fail_test "A payload value ran as a command."

run_step CHECKLY_RERUN_RUN_ID=
assert_failed_with "The re-run payload has no valid run_id."
assert_no_api_calls

# The command substitution must reach the script as literal text.
# shellcheck disable=SC2016
run_step CHECKLY_RERUN_JOB_ID='$(id)'
assert_failed_with "The re-run payload has no valid job_id."
assert_no_api_calls

run_step CHECKLY_RERUN_SHA=0123456789ABCDEF0123456789ABCDEF01234567
assert_failed_with "The re-run payload has no valid sha."
assert_no_api_calls

run_step CHECKLY_RERUN_SHA=0123456
assert_failed_with "The re-run payload has no valid sha."
assert_no_api_calls

# Without gh on the PATH the step fails with a pointer for self-hosted runners.
NO_GH_BIN="$TEST_DIR/no-gh-bin"
mkdir -p "$NO_GH_BIN"
for tool in bash mktemp rm tr sed; do
  ln -s "$(command -v "$tool")" "$NO_GH_BIN/$tool"
done
run_step PATH="$NO_GH_BIN"
assert_failed_with "The GitHub CLI (gh) is not on the PATH. Self-hosted runners need it to re-run the job."

# The job must exist and belong to the payload's run and commit.
write_routes "$(jq -n --arg key "GET repos/${REPOSITORY}/actions/jobs/${JOB_ID}" '{ ($key): [{ status: 404, body: { message: "Not Found" } }] }')"
run_step
assert_failed_with "Could not read job ${JOB_ID}: Not Found (HTTP 404)"

write_routes "$(jq -n --arg key "GET repos/${REPOSITORY}/actions/jobs/${JOB_ID}" --arg sha "$SHA" --arg name "$JOB_NAME" \
  '{ ($key): [{ body: { run_id: 1, head_sha: $sha, name: $name } }] }')"
run_step
assert_failed_with "Job ${JOB_ID} does not belong to run ${RUN_ID}."

write_routes "$(jq -n --arg key "GET repos/${REPOSITORY}/actions/jobs/${JOB_ID}" --argjson run_id "$RUN_ID" --arg name "$JOB_NAME" \
  '{ ($key): [{ body: { run_id: $run_id, head_sha: "ffffffffffffffffffffffffffffffffffffffff", name: $name } }] }')"
run_step
assert_failed_with "Job ${JOB_ID} did not run on commit ${SHA}."

write_routes "$(jq -n --arg key "GET repos/${REPOSITORY}/actions/runs/${RUN_ID}" '{ ($key): [{ status: 404, body: { message: "Not Found" } }] }')"
run_step
assert_failed_with "Could not read run ${RUN_ID}: Not Found (HTTP 404)"

# The latest attempt must have a finished job with the same name.
latest_jobs_key="GET repos/${REPOSITORY}/actions/runs/${RUN_ID}/jobs?filter=latest&per_page=100"
write_routes "$(jq -n --arg key "$latest_jobs_key" '{ ($key): [{ status: 500, body: { message: "Server Error" } }] }')"
run_step
assert_failed_with "Could not list the jobs of run ${RUN_ID}: Server Error (HTTP 500)"

write_routes "$(jq -n --arg key "$latest_jobs_key" '{ ($key): [{ body: { jobs: [{ id: 1, status: "completed", name: "Lint" }] } }] }')"
run_step
assert_failed_with "The latest attempt of run ${RUN_ID} has no job named ${JOB_NAME}."

write_routes "$(jq -n --arg key "$latest_jobs_key" --argjson latest_job_id "$LATEST_JOB_ID" --arg name "$JOB_NAME" \
  '{ ($key): [{ body: { jobs: [{ id: $latest_job_id, status: "in_progress", name: $name }] } }] }')"
run_step
assert_failed_with "Job ${LATEST_JOB_ID} of run ${RUN_ID} is still in progress."

# GitHub's refusal is reported with its message.
write_routes "$(jq -n --arg key "POST repos/${REPOSITORY}/actions/jobs/${LATEST_JOB_ID}/rerun" \
  '{ ($key): [{ status: 403, body: { message: "Resource not accessible by integration" } }] }')"
run_step
[[ "$step_status" -ne 0 ]] || fail_test "Expected a refused re-run to fail."
[[ "$step_output" == *"::error::GitHub did not re-run job ${LATEST_JOB_ID}: Resource not accessible by integration (HTTP 403)"* ]] || fail_test "Expected GitHub's message."
[[ ! -s "$OUTPUT_FILE" ]] || fail_test "Expected no outputs after a refused re-run."

echo "All re-run handler tests passed."
