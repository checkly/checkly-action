#!/usr/bin/env bash
set -Eeuo pipefail

RERUN_EVENT_TYPE="checkly-github-check-rerun"
RUN_STATUS_RETRIES=3
RUN_STATUS_RETRY_SECONDS=30

# A workflow command ends at the first newline. Escape values that come from
# the GitHub API so they cannot start a command of their own.
escape_command_data() {
  local value="${1:-}"
  value="${value//'%'/%25}"
  value="${value//$'\r'/%0D}"
  value="${value//$'\n'/%0A}"
  printf '%s' "$value"
}

fail() {
  echo "::error::$(escape_command_data "$1")" >&2
  exit 1
}

write_output() {
  local name="$1"
  local value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
  fi
}

api_error_file="$(mktemp)"
trap 'rm -f "$api_error_file"' EXIT

github_api() {
  gh api "$@" 2> "$api_error_file"
}

# gh reports a failed request as "gh: <message> (HTTP <status>)".
api_error() {
  tr '\n' ' ' < "$api_error_file" | sed -E 's/^gh: //; s/[[:space:]]+$//'
}

repository="${GITHUB_REPOSITORY:-}"
run_id="${CHECKLY_RERUN_RUN_ID:-}"
job_id="${CHECKLY_RERUN_JOB_ID:-}"
sha="${CHECKLY_RERUN_SHA:-}"

if [[ "${GITHUB_EVENT_NAME:-}" != "repository_dispatch" ]]; then
  fail "The Checkly re-run action handles repository_dispatch events only. This workflow ran for ${GITHUB_EVENT_NAME:-an unknown event}."
fi
if [[ "${CHECKLY_RERUN_EVENT_TYPE:-}" != "$RERUN_EVENT_TYPE" ]]; then
  fail "The repository_dispatch event type is not ${RERUN_EVENT_TYPE}. Add types: [${RERUN_EVENT_TYPE}] to the workflow trigger."
fi
if [[ "${CHECKLY_RERUN_VERSION:-}" != "1" ]]; then
  fail "The re-run payload version is not supported. This action handles version 1."
fi
if [[ -z "$repository" || "${CHECKLY_RERUN_REPOSITORY:-}" != "$repository" ]]; then
  fail "The re-run payload does not name this workflow's repository${repository:+ (${repository})}."
fi
if [[ ! "$run_id" =~ ^[0-9]+$ ]]; then
  fail "The re-run payload has no valid run_id."
fi
if [[ ! "$job_id" =~ ^[0-9]+$ ]]; then
  fail "The re-run payload has no valid job_id."
fi
if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  fail "The re-run payload has no valid sha."
fi

if ! command -v gh >/dev/null 2>&1; then
  fail "The GitHub CLI (gh) is not on the PATH. Self-hosted runners need it to re-run the job."
fi

if ! job="$(github_api "repos/${repository}/actions/jobs/${job_id}" --jq '"\(.run_id)\t\(.head_sha)\t\(.name)"')"; then
  fail "Could not read job ${job_id}: $(api_error)"
fi
IFS=$'\t' read -r job_run_id job_head_sha job_name <<< "$job"
if [[ "$job_run_id" != "$run_id" ]]; then
  fail "Job ${job_id} does not belong to run ${run_id}."
fi
if [[ "$job_head_sha" != "$sha" ]]; then
  fail "Job ${job_id} did not run on commit ${sha}."
fi

retries=0
while true; do
  if ! run="$(github_api "repos/${repository}/actions/runs/${run_id}" --jq '"\(.status)\t\(.html_url)"')"; then
    fail "Could not read run ${run_id}: $(api_error)"
  fi
  IFS=$'\t' read -r run_status run_url <<< "$run"
  if [[ "$run_status" == "completed" ]]; then
    break
  fi
  if (( retries >= RUN_STATUS_RETRIES )); then
    fail "Run ${run_id} is still in progress. Re-run the job from the Actions tab once the run has finished."
  fi
  retries=$((retries + 1))
  echo "Run ${run_id} is still in progress. Checking again in ${RUN_STATUS_RETRY_SECONDS} seconds."
  sleep "$RUN_STATUS_RETRY_SECONDS"
done

# A click on a check from an earlier attempt re-runs the job of the latest
# attempt. Job IDs change between attempts and names do not.
if ! latest_jobs="$(github_api --paginate "repos/${repository}/actions/runs/${run_id}/jobs?filter=latest&per_page=100" --jq '.jobs[] | "\(.id)\t\(.status)\t\(.name)"')"; then
  fail "Could not list the jobs of run ${run_id}: $(api_error)"
fi
latest_job_id=""
latest_job_status=""
while IFS=$'\t' read -r candidate_id candidate_status candidate_name; do
  if [[ "$candidate_id" == "$job_id" || ( -z "$latest_job_id" && "$candidate_name" == "$job_name" ) ]]; then
    latest_job_id="$candidate_id"
    latest_job_status="$candidate_status"
  fi
done <<< "$latest_jobs"
if [[ ! "$latest_job_id" =~ ^[0-9]+$ ]]; then
  fail "The latest attempt of run ${run_id} has no job named ${job_name}."
fi
if [[ "$latest_job_status" != "completed" ]]; then
  fail "Job ${latest_job_id} of run ${run_id} is still in progress."
fi

if ! github_api --method POST "repos/${repository}/actions/jobs/${latest_job_id}/rerun" > /dev/null; then
  fail "GitHub did not re-run job ${latest_job_id}: $(api_error)"
fi

write_output "run-url" "$run_url"
write_output "job-id" "$latest_job_id"
echo "::notice::$(escape_command_data "Re-running job ${job_name} (${latest_job_id}) of run ${run_url}")"
