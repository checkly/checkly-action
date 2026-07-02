#!/usr/bin/env bash
set -Eeuo pipefail

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

falsey() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    false|0|no|n|off) return 0 ;;
    *) return 1 ;;
  esac
}

add_flag_value() {
  local flag="$1"
  local value
  value="$(trim "${2:-}")"
  if [[ -n "$value" ]]; then
    checkly_command+=("$flag" "$value")
  fi
}

add_boolean_flag() {
  local flag="$1"
  local value="${2:-}"
  if truthy "$value"; then
    checkly_command+=("$flag")
  fi
}

add_optional_boolean_flag() {
  local positive_flag="$1"
  local negative_flag="$2"
  local value="${3:-}"
  if [[ -z "$(trim "$value")" ]]; then
    return
  fi
  if truthy "$value"; then
    checkly_command+=("$positive_flag")
  elif falsey "$value"; then
    checkly_command+=("$negative_flag")
  else
    echo "::error::Expected boolean input for ${positive_flag}/${negative_flag}, got '${value}'." >&2
    exit 1
  fi
}

add_repeated_flag_from_lines() {
  local flag="$1"
  local values="${2:-}"
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    if [[ -n "$line" ]]; then
      checkly_command+=("$flag" "$line")
    fi
  done <<< "$values"
}

add_positional_from_lines() {
  local values="${1:-}"
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    if [[ -n "$line" ]]; then
      checkly_command+=("$line")
    fi
  done <<< "$values"
}

write_output() {
  local name="$1"
  local value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
  fi
}

append_summary() {
  local value="$1"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$value" >> "$GITHUB_STEP_SUMMARY"
  fi
}

github_event_value() {
  local path="$1"
  local event_path="${GITHUB_EVENT_PATH:-}"
  if [[ -z "$event_path" || ! -f "$event_path" ]]; then
    return 0
  fi
  if ! command -v node >/dev/null 2>&1; then
    return 0
  fi

  node - "$path" <<'NODE'
const fs = require('fs')

const eventPath = process.env.GITHUB_EVENT_PATH
const path = process.argv[2].split('.')

try {
  let value = JSON.parse(fs.readFileSync(eventPath, 'utf8'))
  for (const segment of path) {
    if (!value || typeof value !== 'object' || !(segment in value)) {
      process.exit(0)
    }
    value = value[segment]
  }
  if (typeof value === 'string' && value.trim() !== '') {
    process.stdout.write(value)
  }
} catch (_) {
  process.exit(0)
}
NODE
}

is_pull_request_event() {
  case "${GITHUB_EVENT_NAME:-}" in
    pull_request|pull_request_target) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_github_repository() {
  local repository=""
  if is_pull_request_event; then
    repository="$(github_event_value "pull_request.head.repo.full_name")"
  fi
  printf '%s' "${repository:-${GITHUB_REPOSITORY:-}}"
}

resolve_github_sha() {
  local sha=""
  if is_pull_request_event; then
    sha="$(github_event_value "pull_request.head.sha")"
  fi
  printf '%s' "${sha:-${GITHUB_SHA:-}}"
}

clear_github_report_env() {
  unset CHECKLY_GITHUB_REPORT
  unset CHECKLY_GITHUB_REPOSITORY
  unset CHECKLY_GITHUB_SHA
  unset CHECKLY_GITHUB_RUN_ID
  unset CHECKLY_GITHUB_RUN_ATTEMPT
  unset CHECKLY_GITHUB_WORKFLOW
  unset CHECKLY_GITHUB_JOB
  unset CHECKLY_GITHUB_EVENT_NAME
  unset CHECKLY_GITHUB_REF
  unset CHECKLY_GITHUB_HEAD_REF
  unset CHECKLY_GITHUB_BASE_REF
  unset CHECKLY_GITHUB_SERVER_URL
}

configure_generic_repo_env() {
  local repository
  repository="$(resolve_github_repository)"
  if [[ -n "$repository" ]]; then
    export CHECKLY_REPO_URL="${CHECKLY_REPO_URL:-${GITHUB_SERVER_URL:-https://github.com}/${repository}}"
  fi

  local sha
  sha="$(resolve_github_sha)"
  if [[ -n "$sha" ]]; then
    export CHECKLY_REPO_SHA="${CHECKLY_REPO_SHA:-$sha}"
  fi

  local branch_name="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-}}"
  if [[ -n "$branch_name" ]]; then
    export CHECKLY_REPO_BRANCH="${CHECKLY_REPO_BRANCH:-$branch_name}"
  fi
}

configure_github_report() {
  local value="${INPUT_GITHUB_REPORT:-true}"
  if falsey "$value"; then
    clear_github_report_env
    return
  fi
  if ! truthy "$value"; then
    echo "::error::Expected boolean input for github-report, got '${value}'." >&2
    exit 1
  fi

  export CHECKLY_GITHUB_REPORT=true

  local repository
  repository="$(resolve_github_repository)"
  if [[ -n "$repository" ]]; then
    export CHECKLY_GITHUB_REPOSITORY="$repository"
  fi

  local sha
  sha="$(resolve_github_sha)"
  if [[ -n "$sha" ]]; then
    export CHECKLY_GITHUB_SHA="$sha"
  fi

  [[ -n "${GITHUB_RUN_ID:-}" ]] && export CHECKLY_GITHUB_RUN_ID="$GITHUB_RUN_ID"
  [[ -n "${GITHUB_RUN_ATTEMPT:-}" ]] && export CHECKLY_GITHUB_RUN_ATTEMPT="$GITHUB_RUN_ATTEMPT"
  [[ -n "${GITHUB_WORKFLOW:-}" ]] && export CHECKLY_GITHUB_WORKFLOW="$GITHUB_WORKFLOW"
  [[ -n "${GITHUB_JOB:-}" ]] && export CHECKLY_GITHUB_JOB="$GITHUB_JOB"
  [[ -n "${GITHUB_EVENT_NAME:-}" ]] && export CHECKLY_GITHUB_EVENT_NAME="$GITHUB_EVENT_NAME"
  [[ -n "${GITHUB_REF:-}" ]] && export CHECKLY_GITHUB_REF="$GITHUB_REF"
  [[ -n "${GITHUB_HEAD_REF:-}" ]] && export CHECKLY_GITHUB_HEAD_REF="$GITHUB_HEAD_REF"
  [[ -n "${GITHUB_BASE_REF:-}" ]] && export CHECKLY_GITHUB_BASE_REF="$GITHUB_BASE_REF"
  [[ -n "${GITHUB_SERVER_URL:-}" ]] && export CHECKLY_GITHUB_SERVER_URL="$GITHUB_SERVER_URL"

  return 0
}

command_name="$(trim "${INPUT_COMMAND:-test}")"
cli_version="$(trim "${INPUT_CLI_VERSION:-latest}")"
working_directory="$(trim "${INPUT_WORKING_DIRECTORY:-.}")"
install_command="$(trim "${INPUT_INSTALL_COMMAND:-}")"

case "$command_name" in
  test|trigger) ;;
  *)
    echo "::error::Unsupported command '${command_name}'. Expected 'test' or 'trigger'." >&2
    exit 1
    ;;
esac

if [[ "$command_name" == "trigger" && -n "$(trim "${INPUT_GREP:-}")" ]]; then
  echo "::error::Input 'grep' is only supported with command=test." >&2
  exit 1
fi

if [[ "$command_name" == "test" && -n "$(trim "${INPUT_CHECK_ID:-}")" ]]; then
  echo "::error::Input 'check-id' is only supported with command=trigger." >&2
  exit 1
fi

if [[ "$command_name" == "trigger" && -n "$(trim "${INPUT_FILES:-}")" ]]; then
  echo "::error::Input 'files' is only supported with command=test." >&2
  exit 1
fi

if [[ "$command_name" == "trigger" && -n "$(trim "${INPUT_UPDATE_SNAPSHOTS:-}")" ]] && truthy "${INPUT_UPDATE_SNAPSHOTS:-}"; then
  echo "::error::Input 'update-snapshots' is only supported with command=test." >&2
  exit 1
fi

if [[ "$command_name" == "trigger" && -n "$(trim "${INPUT_VERIFY_RUNTIME_DEPENDENCIES:-}")" ]]; then
  echo "::error::Input 'verify-runtime-dependencies' is only supported with command=test." >&2
  exit 1
fi

if [[ "$command_name" == "test" && -n "$(trim "${INPUT_FAIL_ON_NO_MATCHING:-}")" ]]; then
  echo "::error::Input 'fail-on-no-matching' is only supported with command=trigger." >&2
  exit 1
fi

checkly_command=(npx --yes "checkly@${cli_version}" "$command_name" --detach)

add_repeated_flag_from_lines "--tags" "${INPUT_TAGS:-}"
add_flag_value "--config" "${INPUT_CONFIG:-}"
add_flag_value "--location" "${INPUT_LOCATION:-}"
add_flag_value "--private-location" "${INPUT_PRIVATE_LOCATION:-}"
add_repeated_flag_from_lines "--env" "${INPUT_ENV:-}"
add_flag_value "--env-file" "${INPUT_ENV_FILE:-}"
add_flag_value "--test-session-name" "${INPUT_TEST_SESSION_NAME:-}"
add_flag_value "--timeout" "${INPUT_TIMEOUT:-}"
add_flag_value "--retries" "${INPUT_RETRIES:-}"
add_boolean_flag "--refresh-cache" "${INPUT_REFRESH_CACHE:-}"
add_optional_boolean_flag "--verbose" "--no-verbose" "${INPUT_VERBOSE:-}"

if [[ "$command_name" == "test" ]]; then
  add_flag_value "--grep" "${INPUT_GREP:-}"
  add_boolean_flag "--update-snapshots" "${INPUT_UPDATE_SNAPSHOTS:-}"
  add_optional_boolean_flag "--verify-runtime-dependencies" "--no-verify-runtime-dependencies" "${INPUT_VERIFY_RUNTIME_DEPENDENCIES:-}"
  add_positional_from_lines "${INPUT_FILES:-}"
else
  add_flag_value "--check-id" "${INPUT_CHECK_ID:-}"
  add_optional_boolean_flag "--fail-on-no-matching" "--no-fail-on-no-matching" "${INPUT_FAIL_ON_NO_MATCHING:-}"
fi

configure_generic_repo_env
configure_github_report

if [[ "${CHECKLY_ACTION_DRY_RUN:-}" == "1" || "${CHECKLY_ACTION_DRY_RUN:-}" == "true" ]]; then
  if [[ -n "$install_command" ]]; then
    printf 'Install command: %s\n' "$install_command"
  fi
  printf 'Command: '
  printf '%q ' "${checkly_command[@]}"
  printf '\n'
  if [[ "${CHECKLY_GITHUB_REPORT:-}" == "true" ]]; then
    printf 'GitHub report: enabled'
    if [[ -n "${CHECKLY_GITHUB_REPOSITORY:-}" && -n "${CHECKLY_GITHUB_SHA:-}" ]]; then
      printf ' for %s@%s' "$CHECKLY_GITHUB_REPOSITORY" "$CHECKLY_GITHUB_SHA"
    fi
    printf '\n'
  else
    printf 'GitHub report: disabled\n'
  fi
  exit 0
fi

cd "$working_directory"

if [[ -n "$install_command" ]]; then
  echo "Running install command: ${install_command}"
  bash -euo pipefail -c "$install_command"
fi

output_file="$(mktemp)"
set +e
"${checkly_command[@]}" 2>&1 | tee "$output_file"
status="${PIPESTATUS[0]}"
set -e

plain_output="$(perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g' "$output_file")"
test_session_id="$(printf '%s\n' "$plain_output" | sed -nE 's/.*Test session ID:[[:space:]]*([A-Za-z0-9_-]+).*/\1/p' | tail -n 1)"
test_session_url="$(printf '%s\n' "$plain_output" | sed -nE 's/.*Open session:[[:space:]]*(https?:\/\/[^[:space:]]+).*/\1/p' | tail -n 1)"

if [[ -n "$test_session_id" ]]; then
  write_output "test-session-id" "$test_session_id"
fi

if [[ -n "$test_session_url" ]]; then
  write_output "test-session-url" "$test_session_url"
fi

append_summary "## Checkly"
append_summary ""
if [[ -n "$test_session_id" ]]; then
  append_summary "- Test session ID: \`${test_session_id}\`"
fi
if [[ -n "$test_session_url" ]]; then
  append_summary "- Open session: ${test_session_url}"
fi
if [[ -z "$test_session_id" && -z "$test_session_url" ]]; then
  append_summary "- The Checkly CLI did not print a detached test session reference."
fi

if truthy "${INPUT_GITHUB_REPORT:-true}"; then
  append_summary ""
  append_summary "GitHub Check reporting is best-effort. If the Checkly GitHub App is not connected to this repository, use the test session link above."
fi

rm -f "$output_file"
exit "$status"
