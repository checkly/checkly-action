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
      - uses: actions/checkout@v6

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

Cancelling a job that waits also cancels its Checkly test session. This covers
runs superseded through `concurrency` with `cancel-in-progress`. A detached run
keeps running in Checkly after its job ends.
To cancel the detached sessions of earlier pushes to a pull request, see [Cancel superseded sessions](#cancel-superseded-sessions).

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
      - uses: actions/checkout@v6
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

### Re-run a detached check

A detached run reports through a Checkly GitHub Check. The Re-run button on that check therefore goes to Checkly. Set `github-check-rerun: true` to make that button re-run the GitHub Actions job that started the test session. GitHub re-runs the job and the jobs that depend on it as a new attempt of the same workflow run. The new attempt uses the same commit, the same workflow file and the privileges of the actor who started the original run. The re-run job starts a new test session. That session reports a new check with the same name on the same commit.

Pass the ID of the job with `github-job-id: ${{ job.check_run_id }}`. The `job.check_run_id` property is not available on GitHub Enterprise Server. When the run detaches and `github-job-id` is empty, the step fails before it runs any checks. With `reporting: github-actions`, the action ignores `github-check-rerun` and logs a warning. A run that falls back to waiting in the job ignores it as well.

Re-run needs Checkly CLI `10.1.0` or newer. Older versions do not send the job ID to Checkly. When the run detaches with an older CLI, the step fails before it runs any checks. Raise the project's `checkly` dependency or the `cli-version` input to `10.1.0` or newer. Dist-tags such as `latest`, ranges, canaries, and prereleases pass this check.

```yaml
jobs:
  e2e:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6

      - uses: checkly/checkly-action@v1
        with:
          command: test
          install-command: npm ci
          reporting: github-check
          github-check-name: e2e
          github-check-rerun: true
          github-job-id: ${{ job.check_run_id }}
        env:
          CHECKLY_API_KEY: ${{ secrets.CHECKLY_API_KEY }}
          CHECKLY_ACCOUNT_ID: ${{ vars.CHECKLY_ACCOUNT_ID }}
```

When someone clicks Re-run, Checkly sends a `repository_dispatch` event of type `checkly-github-check-rerun` to the repository. Add a handler workflow on the default branch that passes the event to the `rerun` sub-action. GitHub runs `repository_dispatch` workflows from the default branch only.

```yaml
name: Checkly re-run

on:
  repository_dispatch:
    types: [checkly-github-check-rerun]

permissions: {}

jobs:
  rerun:
    runs-on: ubuntu-latest
    permissions:
      actions: write
    timeout-minutes: 5
    steps:
      - uses: checkly/checkly-action/rerun@v1
```

The handler's `GITHUB_TOKEN` needs `actions: write` and nothing else. The handler checks out no code and uses no secrets. It re-runs jobs of its own repository only. Before it re-runs anything, it checks that the job belongs to the workflow run and the commit named in the event. It waits up to 90 seconds for the workflow run to finish. A click on a check from an earlier attempt re-runs the job with the same name in the latest attempt. Self-hosted runners need the GitHub CLI (`gh`) on the `PATH`.

Keep the `types` filter in the handler. Any workflow with an unfiltered `on: repository_dispatch` trigger also runs on every Re-run click. GitHub allows re-runs up to 30 days after a workflow run, with at most 50 re-runs per run.

| Handler input | Description |
| --- | --- |
| `github-token` | Token that re-runs the job. Needs `actions: write`. Defaults to `${{ github.token }}`. |

| Handler output | Description |
| --- | --- |
| `run-url` | URL of the workflow run whose job was re-run. |
| `job-id` | ID of the re-run job in the latest attempt of the workflow run. |

### Cancel superseded sessions

A detached test session keeps running after its job ends. A new push to a pull request therefore leaves the session of the previous commit running. That session still reports its check on the old commit. Set `cancel-superseded: true` to cancel those sessions before the new run starts.

The action looks at the commit that the push replaced and at the ten most recent commits of the pull request before its head. On each of those commits, it looks for in-progress checks with the same name as this run's GitHub Check. It cancels the Checkly test session behind each check it finds. Checkly then completes that check as cancelled.

Cancelling applies only to detached runs on `pull_request` and `pull_request_target` events. Merge queue runs and runs that wait in the job are not affected. The job's token needs `checks: read` and `pull-requests: read`. Set `github-token` to use a different token.

Cancelling never fails the run. Each GitHub or Checkly API request gives up after 5 seconds. A failed request becomes a warning. A session that belongs to another Checkly account is skipped with a warning.

```yaml
on:
  pull_request:

permissions:
  contents: read
  checks: read
  pull-requests: read

jobs:
  checkly:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6

      - uses: checkly/checkly-action@v1
        with:
          command: test
          install-command: npm ci
          reporting: github-check
          cancel-superseded: true
        env:
          CHECKLY_API_KEY: ${{ secrets.CHECKLY_API_KEY }}
          CHECKLY_ACCOUNT_ID: ${{ vars.CHECKLY_ACCOUNT_ID }}
```

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
| `github-check-rerun` | Let the Re-run button on the Checkly GitHub Check re-run this job. Needs `github-job-id`, Checkly CLI `10.1.0` or newer, and a [handler workflow](#re-run-a-detached-check). Applies to detached runs only. Defaults to `false`. |
| `github-job-id` | ID of the job that runs this step. Set it to `${{ job.check_run_id }}`. Required when `github-check-rerun` is `true`. |
| `cancel-superseded` | On pull request events, cancel the detached test sessions of earlier commits that still report a GitHub Check with the same name. Defaults to `false`. |
| `github-token` | Token used to find superseded GitHub Checks. Needs `checks: read` and `pull-requests: read`. Defaults to `${{ github.token }}`. |

## Outputs

| Output | Description |
| --- | --- |
| `test-session-id` | Checkly test session ID, when detected from CLI output. |
| `test-session-url` | Checkly test session URL, when detected from CLI output. |

## Development

The test harness does not need Checkly or GitHub credentials. It uses a local
preflight server and a fake CLI process to exercise the complete Action flow.
The re-run handler tests use a fake GitHub CLI and need `jq`.

```sh
shellcheck scripts/*.sh
./scripts/test.sh
./scripts/test-integration.sh
./scripts/test-rerun.sh
```

See `AGENTS.md` for the repository invariants, complete verification commands,
and release guidance.
