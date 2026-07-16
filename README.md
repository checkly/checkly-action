# Checkly GitHub Action

Run Checkly checks from GitHub Actions with the Checkly CLI.

This action is a small wrapper around `npx checkly@<version> test` and
`npx checkly@<version> trigger`. It keeps the Checkly CLI as the source of truth
while making the common GitHub Actions setup easier to discover.

## Usage

Run local Checkly constructs from the pull request checkout:

```yaml
name: Checkly

on:
  pull_request:

jobs:
  checkly:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: checkly/checkly-action@v1
        with:
          command: test
          cli-version: latest
          install-command: npm ci
          tags: production,webapp
          grep: checkout
          github-check-name: Checkly PR code checks
        env:
          CHECKLY_API_KEY: ${{ secrets.CHECKLY_API_KEY }}
          CHECKLY_ACCOUNT_ID: ${{ vars.CHECKLY_ACCOUNT_ID }}
```

Trigger deployed checks from Checkly:

```yaml
- uses: checkly/checkly-action@v1
  with:
    command: trigger
    tags: production
    check-id: abc123,def456
  env:
    CHECKLY_API_KEY: ${{ secrets.CHECKLY_API_KEY }}
    CHECKLY_ACCOUNT_ID: ${{ vars.CHECKLY_ACCOUNT_ID }}
```

Use multiple `--tags` filters by putting one filter per line:

```yaml
with:
  command: test
  tags: |
    production,webapp
    production,backend
```

The `reporting` input controls where the Checkly result is reported:

- `auto` (default): use a detached run with GitHub Check reporting when the
  Checkly GitHub App can report on the repository. Otherwise, wait in the
  GitHub Actions job and report there.
- `github-check`: require detached GitHub Check reporting. The action fails
  before running checks if the Checkly GitHub App cannot report on the
  repository.
- `github-actions`: always wait in the GitHub Actions job and report through the
  CLI GitHub reporter and step summary.

Install the [Checkly GitHub App](https://app.checklyhq.com/settings/account/integrations)
from your Checkly account integrations and grant it access to the repository to
use detached GitHub Check reporting.

### CLI resolution

Checkly config files import constructs from the `checkly` package. When the
working directory has `checkly` installed, this action runs that local CLI after
`install-command` completes so the CLI and constructs share the same module
session. Keep that project dependency at `8.15.0` or newer for GitHub Check
reporting.

An exact stable `cli-version` pin must match the installed project version. For
example, a project with `checkly@8.15.0` should use `cli-version: 8.15.0`. The
action falls back to `npx checkly@<cli-version>` only when the project does not
install Checkly itself.

For `deployment_status` workflows, the action exposes
`github.event.deployment_status.environment_url` as `ENVIRONMENT_URL` when that
environment variable is not already set. For pull request preview URLs, pass the
target URL explicitly through `env` or the workflow `env` block.

### Choose the GitHub Check commit

GitHub Checks are attached to a commit, not to a workflow run or deployment.
For pull request events, the action targets the pull request head commit. For
other events, it uses `GITHUB_SHA`.

Set `github-sha` when the commit being tested differs from `GITHUB_SHA`. This is
common in `repository_dispatch` workflows, where the dispatch payload identifies
the deployed commit. Use the same SHA for checkout and Check reporting so the
result describes the code that actually ran:

```yaml
name: Validate preview

on:
  repository_dispatch:
    types: [preview-ready]

jobs:
  checkly:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.client_payload.sha }}

      - uses: checkly/checkly-action@v1
        with:
          command: test
          install-command: npm ci
          github-sha: ${{ github.event.client_payload.sha }}
          github-check-name: Checkly preview validation
        env:
          CHECKLY_API_KEY: ${{ secrets.CHECKLY_API_KEY }}
          CHECKLY_ACCOUNT_ID: ${{ vars.CHECKLY_ACCOUNT_ID }}
          ENVIRONMENT_URL: ${{ github.event.client_payload.environment_url }}
```

The commit must belong to the current repository. The Checkly backend still
verifies that the account's GitHub App installation can access that repository;
`github-sha` is metadata, not authorization. It associates the test session
with that commit and selects where the GitHub Check is reported.

## Inputs

| Input | Description |
| --- | --- |
| `command` | `test` for local constructs or `trigger` for deployed checks. Defaults to `test`. |
| `cli-version` | Checkly CLI version. Requires `8.15.0` or newer and defaults to `latest`. When the project installs `checkly`, the local CLI runs instead; exact stable pins must match it. Dist-tags, ranges, canaries, and prereleases are assumed compatible. |
| `working-directory` | Directory where the CLI command should run. Defaults to `.`. |
| `install-command` | Optional command to run before the Checkly CLI command, inside `working-directory`. |
| `tags` | One `--tags` filter per line. Each line can contain comma-separated tags. |
| `grep` | `test` only. Check name regular expression. |
| `check-id` | `trigger` only. Comma-separated deployed check IDs. |
| `files` | `test` only. File-name patterns passed as positional args, one per line. |
| `config` | Checkly config file path. |
| `location` | Public run location. |
| `private-location` | Private run location slug. |
| `env` | One `KEY=VALUE` per line, passed as repeated `--env` flags. |
| `env-file` | Dotenv file path. |
| `test-session-name` | Name to use for the recorded test session. |
| `timeout` | CLI timeout in seconds. |
| `retries` | Number of retries. |
| `refresh-cache` | Pass `--refresh-cache`. |
| `update-snapshots` | `test` only. Pass `--update-snapshots`. |
| `verify-runtime-dependencies` | `test` only. Set to `false` to pass `--no-verify-runtime-dependencies`. |
| `fail-on-no-matching` | `trigger` only. Set to `false` to pass `--no-fail-on-no-matching`. |
| `verbose` | Set to `true` or `false` to pass `--verbose` or `--no-verbose`. |
| `reporting` | Where to report the Checkly result: `auto`, `github-check`, or `github-actions`. Defaults to `auto`. |
| `github-check-name` | GitHub Check name used when reporting through the Checkly GitHub App. Defaults to `Checkly`. |
| `github-sha` | Commit associated with the test session and targeted by the GitHub Check. Overrides the pull request head SHA or `GITHUB_SHA`. |

## Outputs

| Output | Description |
| --- | --- |
| `test-session-id` | Checkly test session ID, when detected from CLI output. |
| `test-session-url` | Checkly test session URL, when detected from CLI output. |

## Development

The test harness does not need Checkly or GitHub credentials. It uses a local
preflight server and a fake CLI process to exercise the complete Action flow.

```sh
shellcheck scripts/*.sh
./scripts/test.sh
./scripts/test-integration.sh
```

See `AGENTS.md` for the repository invariants, complete verification commands,
and release guidance.
