# Checkly GitHub Action

This repository publishes a composite GitHub Action. There is no build step or
generated distribution bundle: consumers execute `action.yml` and
`scripts/run.sh` directly from the selected Git ref.

## Source Of Truth

- `action.yml` is the public input/output contract.
- `scripts/run.sh` validates inputs, selects the reporting mode, performs the
  preflight request, invokes the Checkly CLI, and writes Action outputs.
- `README.md` documents the public contract and must stay aligned with
  `action.yml`.
- `scripts/test.sh` covers validation and command construction through the
  script's public environment-variable interface.
- `scripts/test-integration.sh` covers the real preflight, CLI invocation,
  working directory, install command, outputs, summaries, and exit codes using
  local fakes. It must never require Checkly or GitHub credentials.

## Product Invariants

- Only `checkly test` and `checkly trigger` are supported. Do not turn `command`
  into an arbitrary shell or CLI escape hatch.
- CLI options remain separate Action inputs so workflows do not need to build
  command strings.
- `reporting: auto` detaches only after the backend preflight confirms GitHub
  Check writeback is available. Otherwise it waits and reports through GitHub
  Actions.
- `reporting: github-check` fails before scheduling checks when writeback is not
  available. `reporting: github-actions` never detaches.
- The Action requires Checkly CLI `8.15.0` or newer. A pinned older stable
  version must fail before running or performing a preflight request.
- Exact stable semver pins are compared against the minimum version. Dist-tags,
  ranges, canaries, and prereleases are allowed because they may identify a
  compatible build before the next stable release.
- Repository and SHA values sent by the Action are hints, not authorization.
  The Checkly backend must continue verifying account-scoped GitHub App access.
- Never print API keys or other secrets. Sanitize backend-provided values before
  placing them in GitHub workflow commands or summaries.

## Verification

Run all of these before pushing:

```bash
bash -n scripts/*.sh
node --check scripts/test-preflight-server.cjs
shellcheck scripts/*.sh
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint@sha256:887a259a5a534f3c4f36cb02dca341673c6089431057242cdc931e9f133147e9
./scripts/test.sh
./scripts/test-integration.sh
```

CI runs the harness on Linux and macOS, invokes the composite Action itself to
catch drift between `action.yml` and `scripts/run.sh`, and exposes the stable
`CI` aggregator check for branch protection.

When adding behavior, add a failing public-behavior test first, make the minimum
implementation change, then run the complete verification set. Keep tests
deterministic and local; production API calls belong in a separate canary, not
the PR gate.

## Releases

- Do not publish or move release tags from a PR workflow.
- Use immutable full-version tags for releases.
- Only move a major convenience tag such as `v1` after the corresponding full
  release has been verified.
- Coordinate Action features that depend on new CLI metadata with the CLI
  release. The Action must not advertise a pinned CLI version that silently
  drops a requested public input.
