#!/usr/bin/env bash
set -Eeuo pipefail

CHECKLY_GITHUB_INTEGRATION_URL="https://app.checklyhq.com/settings/account/integrations"

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

cli_version_is_supported() {
  local version
  version="$(trim "${1:-}")"

  # Only exact pinned stable semver is comparable against the 8.15.0 floor.
  # Dist-tags, ranges, canaries, and prereleases pass because they may point
  # at compatible builds before a stable release exists.
  if [[ "$version" =~ ^v?([0-9]+)\.([0-9]+)\.[0-9]+$ ]]; then
    local major="${BASH_REMATCH[1]}"
    local minor="${BASH_REMATCH[2]}"

    if (( major < 8 || (major == 8 && minor < 15) )); then
      return 1
    fi
  fi

  return 0
}

# Reasons are interpolated into ::warning:: workflow commands and the step
# summary; constrain them to a safe charset so a malformed or hostile
# preflight response can never inject workflow commands or extra lines.
sanitize_reason() {
  local value
  value="$(printf '%s' "${1:-}" | tr -cd 'a-z0-9_')"
  printf '%s' "${value:-unavailable}"
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
  } else if (typeof value === 'number' && Number.isFinite(value)) {
    process.stdout.write(String(value))
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
  unset CHECKLY_GITHUB_SOURCE
  unset CHECKLY_GITHUB_CHECK_NAME
  unset CHECKLY_GITHUB_PULL_REQUEST_NUMBER
  unset CHECKLY_GITHUB_ENVIRONMENT_URL
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
  local repository="$1"
  local sha="$2"

  if [[ -n "$repository" ]]; then
    export CHECKLY_REPO_URL="${CHECKLY_REPO_URL:-${GITHUB_SERVER_URL:-https://github.com}/${repository}}"
  fi

  if [[ -n "$sha" ]]; then
    export CHECKLY_REPO_SHA="${CHECKLY_REPO_SHA:-$sha}"
  fi

  local branch_name="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-}}"
  if [[ -n "$branch_name" ]]; then
    export CHECKLY_REPO_BRANCH="${CHECKLY_REPO_BRANCH:-$branch_name}"
  fi
}

configure_deployment_environment_url() {
  local deployment_url
  deployment_url="$(github_event_value "deployment_status.environment_url")"
  if [[ -n "$deployment_url" && -z "${ENVIRONMENT_URL:-}" ]]; then
    export ENVIRONMENT_URL="$deployment_url"
  fi
}

configure_github_report() {
  local repository="$1"
  local sha="$2"
  local github_check_name="$3"

  export CHECKLY_GITHUB_REPORT=true
  export CHECKLY_GITHUB_SOURCE=checkly-action

  if [[ -n "$github_check_name" ]]; then
    export CHECKLY_GITHUB_CHECK_NAME="$github_check_name"
  fi

  if is_pull_request_event; then
    local pull_request_number
    pull_request_number="$(github_event_value "pull_request.number")"
    if [[ -n "$pull_request_number" ]]; then
      export CHECKLY_GITHUB_PULL_REQUEST_NUMBER="$pull_request_number"
    fi
  fi

  if [[ -n "${ENVIRONMENT_URL:-}" ]]; then
    export CHECKLY_GITHUB_ENVIRONMENT_URL="$ENVIRONMENT_URL"
  fi

  if [[ -n "$repository" ]]; then
    export CHECKLY_GITHUB_REPOSITORY="$repository"
  fi

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

resolve_checkly_api_url() {
  if [[ -n "${CHECKLY_API_URL:-}" ]]; then
    printf '%s' "${CHECKLY_API_URL%/}"
    return
  fi

  case "${CHECKLY_ENV:-production}" in
    local) printf '%s' "http://127.0.0.1:3000" ;;
    development) printf '%s' "https://api-dev.checklyhq.com" ;;
    staging) printf '%s' "https://api-test.checklyhq.com" ;;
    *) printf '%s' "https://api.checklyhq.com" ;;
  esac
}

github_report_preflight() {
  if [[ -n "${CHECKLY_ACTION_GITHUB_REPORT_AVAILABLE:-}" ]]; then
    if truthy "${CHECKLY_ACTION_GITHUB_REPORT_AVAILABLE}"; then
      printf 'true\tavailable\n'
    else
      printf 'false\t%s\n' "${CHECKLY_ACTION_GITHUB_REPORT_REASON:-unavailable}"
    fi
    return
  fi

  if [[ "${CHECKLY_ACTION_DRY_RUN:-}" == "1" || "${CHECKLY_ACTION_DRY_RUN:-}" == "true" ]]; then
    printf 'false\tdry_run\n'
    return
  fi

  if [[ -z "${CHECKLY_API_KEY:-}" || -z "${CHECKLY_ACCOUNT_ID:-}" ]]; then
    printf 'false\tmissing_credentials\n'
    return
  fi

  if [[ -z "${CHECKLY_GITHUB_REPOSITORY:-}" || -z "${CHECKLY_GITHUB_SHA:-}" ]]; then
    printf 'false\tmissing_metadata\n'
    return
  fi

  if ! command -v node >/dev/null 2>&1; then
    printf 'false\tnode_unavailable\n'
    return
  fi

  CHECKLY_PREFLIGHT_API_URL="$(resolve_checkly_api_url)" \
  CHECKLY_PREFLIGHT_CLI_VERSION="$cli_version" \
  node <<'NODE'
const apiUrl = process.env.CHECKLY_PREFLIGHT_API_URL
const accountId = process.env.CHECKLY_ACCOUNT_ID
const apiKey = process.env.CHECKLY_API_KEY

const payload = {
  source: process.env.CHECKLY_GITHUB_SOURCE,
  githubCheckName: process.env.CHECKLY_GITHUB_CHECK_NAME,
  pullRequestNumber: process.env.CHECKLY_GITHUB_PULL_REQUEST_NUMBER,
  environmentUrl: process.env.CHECKLY_GITHUB_ENVIRONMENT_URL,
  repository: process.env.CHECKLY_GITHUB_REPOSITORY,
  sha: process.env.CHECKLY_GITHUB_SHA,
  runId: process.env.CHECKLY_GITHUB_RUN_ID,
  runAttempt: process.env.CHECKLY_GITHUB_RUN_ATTEMPT,
  workflow: process.env.CHECKLY_GITHUB_WORKFLOW,
  job: process.env.CHECKLY_GITHUB_JOB,
  eventName: process.env.CHECKLY_GITHUB_EVENT_NAME,
  ref: process.env.CHECKLY_GITHUB_REF,
  headRef: process.env.CHECKLY_GITHUB_HEAD_REF,
  baseRef: process.env.CHECKLY_GITHUB_BASE_REF,
  serverUrl: process.env.CHECKLY_GITHUB_SERVER_URL,
}

async function main() {
  try {
    const response = await fetch(`${apiUrl}/next/test-sessions/github-checks/preflight`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${apiKey}`,
        'content-type': 'application/json',
        'user-agent': 'checkly-action',
        'x-checkly-account': accountId,
        'x-checkly-source': 'CLI',
        'x-checkly-operator': 'github-actions',
        'x-checkly-ci-name': 'GitHub Actions',
        'x-checkly-cli-version': process.env.CHECKLY_PREFLIGHT_CLI_VERSION ?? '',
      },
      body: JSON.stringify(payload),
      // The preflight is advisory: never let a slow backend hold up the run.
      signal: AbortSignal.timeout(10_000),
    })

    if (!response.ok) {
      process.stdout.write(`false\tpreflight_http_${response.status}\n`)
      return
    }

    const result = await response.json()
    process.stdout.write(`${result.available ? 'true' : 'false'}\t${result.reason || 'unavailable'}\n`)
  } catch (_) {
    process.stdout.write('false\tpreflight_failed\n')
  }
}

main()
NODE
}

command_name="$(trim "${INPUT_COMMAND:-test}")"
cli_version="$(trim "${INPUT_CLI_VERSION:-latest}")"
working_directory="$(trim "${INPUT_WORKING_DIRECTORY:-.}")"
install_command="$(trim "${INPUT_INSTALL_COMMAND:-}")"
reporting="$(trim "${INPUT_REPORTING:-auto}")"
github_check_name="$(trim "${INPUT_GITHUB_CHECK_NAME:-}")"

case "$command_name" in
  test|trigger) ;;
  *)
    echo "::error::Unsupported command '${command_name}'. Expected 'test' or 'trigger'." >&2
    exit 1
    ;;
esac

case "$reporting" in
  auto|github-check|github-actions) ;;
  *)
    echo "::error::Unsupported reporting '${reporting}'. Expected 'auto', 'github-check', or 'github-actions'." >&2
    exit 1
    ;;
esac

if ! cli_version_is_supported "$cli_version"; then
  echo "::error::The Checkly Action needs Checkly CLI 8.15.0 or newer (cli-version is '${cli_version}'). Use cli-version: latest or >= 8.15.0." >&2
  exit 1
fi

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

# Resolve the repository/sha once; both the generic repo env and the GitHub
# report env derive from the same values.
github_repository="$(resolve_github_repository)"
github_sha="$(resolve_github_sha)"

configure_generic_repo_env "$github_repository" "$github_sha"
configure_deployment_environment_url

github_check_requested=false
github_report_available=false
github_report_reason="disabled"
detach_run=false
github_reporter_run=true

if [[ "$reporting" == "github-actions" ]]; then
  clear_github_report_env
else
  github_check_requested=true
  configure_github_report "$github_repository" "$github_sha" "$github_check_name"
  preflight_result="$(github_report_preflight)" || preflight_result=$'false\tpreflight_crashed'
  IFS=$'\t' read -r github_report_available github_report_reason <<< "$preflight_result"
  github_report_reason="$(sanitize_reason "$github_report_reason")"
  if [[ "$github_report_available" == "true" ]]; then
    detach_run=true
    github_reporter_run=false
  else
    clear_github_report_env
    if [[ "$reporting" == "github-check" ]]; then
      echo "::error::Checkly GitHub Check reporting is unavailable (${github_report_reason}). Install the Checkly GitHub App on this repository to run detached and receive a Checkly GitHub Check: ${CHECKLY_GITHUB_INTEGRATION_URL}" >&2
      exit 1
    elif [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
      echo "::warning::Checkly GitHub Check reporting is unavailable (${github_report_reason}). Reporting through GitHub Actions instead, so this job waits for the Checkly test session result. Install the Checkly GitHub App on this repository to run detached and receive a Checkly GitHub Check: ${CHECKLY_GITHUB_INTEGRATION_URL}"
    fi
  fi
fi

checkly_command=(npx --yes "checkly@${cli_version}" "$command_name")
if [[ "$detach_run" == "true" ]]; then
  checkly_command+=("--detach")
elif [[ "$github_reporter_run" == "true" ]]; then
  checkly_command+=("--reporter=github")
fi

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

if [[ "${CHECKLY_ACTION_DRY_RUN:-}" == "1" || "${CHECKLY_ACTION_DRY_RUN:-}" == "true" ]]; then
  if [[ -n "$install_command" ]]; then
    printf 'Install command: %s\n' "$install_command"
  fi
  if [[ -n "${ENVIRONMENT_URL:-}" ]]; then
    printf 'Environment URL: %s\n' "$ENVIRONMENT_URL"
  fi
  printf 'Command: '
  printf '%q ' "${checkly_command[@]}"
  printf '\n'
  if [[ "$reporting" == "github-actions" ]]; then
    printf 'Reporting: GitHub Actions\n'
  elif [[ "$github_check_requested" == "true" && "$github_report_available" == "true" ]]; then
    printf 'Reporting: GitHub Check'
    if [[ -n "${CHECKLY_GITHUB_CHECK_NAME:-}" ]]; then
      printf ' "%s"' "$CHECKLY_GITHUB_CHECK_NAME"
    fi
    if [[ -n "${CHECKLY_GITHUB_REPOSITORY:-}" && -n "${CHECKLY_GITHUB_SHA:-}" ]]; then
      printf ' for %s@%s' "$CHECKLY_GITHUB_REPOSITORY" "$CHECKLY_GITHUB_SHA"
    fi
    printf '\n'
    printf 'GitHub metadata: source=%s' "${CHECKLY_GITHUB_SOURCE:-}"
    if [[ -n "${CHECKLY_GITHUB_PULL_REQUEST_NUMBER:-}" ]]; then
      printf ' pullRequestNumber=%s' "$CHECKLY_GITHUB_PULL_REQUEST_NUMBER"
    fi
    if [[ -n "${CHECKLY_GITHUB_ENVIRONMENT_URL:-}" ]]; then
      printf ' environmentUrl=%s' "$CHECKLY_GITHUB_ENVIRONMENT_URL"
    fi
    printf '\n'
  elif [[ "$github_check_requested" == "true" ]]; then
    printf 'Reporting: GitHub Actions (GitHub Check unavailable: %s)\n' "$github_report_reason"
  else
    printf 'Reporting: GitHub Actions\n'
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

if [[ -f checkly-github-report.md && -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat checkly-github-report.md >> "$GITHUB_STEP_SUMMARY"
  append_summary ""
fi

if [[ -n "$test_session_id" ]]; then
  append_summary "- Test session ID: \`${test_session_id}\`"
fi
if [[ -n "$test_session_url" ]]; then
  append_summary "- Open session: ${test_session_url}"
fi
if [[ -z "$test_session_id" && -z "$test_session_url" ]]; then
  append_summary "- The Checkly CLI did not print a detached test session reference."
fi

if [[ "$github_check_requested" == "true" && "$github_report_available" == "true" ]]; then
  append_summary ""
  append_summary "GitHub Check reporting is enabled for this run."
elif [[ "$github_check_requested" == "true" ]]; then
  append_summary ""
  append_summary "GitHub Check reporting was unavailable (${github_report_reason}). This job reported through GitHub Actions and waited for the Checkly run to finish. [Install the Checkly GitHub App](${CHECKLY_GITHUB_INTEGRATION_URL}) on this repository to run detached and receive a Checkly GitHub Check."
fi

rm -f "$output_file"
exit "$status"
