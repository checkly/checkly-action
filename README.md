# Checkly GitHub Action

Run Checkly checks from GitHub Actions with the Checkly CLI.

This action is a small wrapper around `npx checkly@<version> test --detach` and
`npx checkly@<version> trigger --detach`. It keeps the Checkly CLI as the source
of truth while making the common GitHub Actions setup easier to discover.

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
        env:
          CHECKLY_API_KEY: ${{ secrets.CHECKLY_API_KEY }}
          CHECKLY_ACCOUNT_ID: ${{ secrets.CHECKLY_ACCOUNT_ID }}
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
    CHECKLY_ACCOUNT_ID: ${{ secrets.CHECKLY_ACCOUNT_ID }}
```

Use multiple `--tags` filters by putting one filter per line:

```yaml
with:
  command: test
  tags: |
    production,webapp
    production,backend
```

The action always starts detached runs. The Checkly CLI prints a test session ID
and session URL; this action exposes them as outputs and writes them to the
GitHub Actions step summary.

## Inputs

| Input | Description |
| --- | --- |
| `command` | `test` for local constructs or `trigger` for deployed checks. Defaults to `test`. |
| `cli-version` | Checkly CLI npm version. Defaults to `latest`. |
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
| `github-report` | Best-effort GitHub Check reporting when the Checkly GitHub App is connected. Defaults to `true`. |

## Outputs

| Output | Description |
| --- | --- |
| `test-session-id` | Detached Checkly test session ID, when detected from CLI output. |
| `test-session-url` | Detached Checkly test session URL, when detected from CLI output. |

## Local test

```sh
./scripts/test.sh
```
