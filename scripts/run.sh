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

if [[ "${CHECKLY_ACTION_DRY_RUN:-}" == "1" || "${CHECKLY_ACTION_DRY_RUN:-}" == "true" ]]; then
  if [[ -n "$install_command" ]]; then
    printf 'Install command: %s\n' "$install_command"
  fi
  printf 'Command: '
  printf '%q ' "${checkly_command[@]}"
  printf '\n'
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
