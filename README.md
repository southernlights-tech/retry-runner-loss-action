# retry-runner-loss-action

A composite action that decides whether a failed or cancelled workflow run was
killed by self-hosted runner loss (an EC2 Spot reclaim) and, only then, re-runs
it. The primary signal is the runner-shutdown signature in the job log, with a
bounded check-run-annotation fallback used only when the log cannot be read at
all.

## Usage

```yaml
name: Retry on runner loss
on:
  workflow_run:
    workflows:
      - Test
      - Deploy to Dev
    types: [completed]
permissions:
  contents: read
  actions: write
  pull-requests: write
  checks: read
jobs:
  retry:
    if: ${{ github.event.workflow_run.conclusion == 'failure' || github.event.workflow_run.conclusion == 'cancelled' }}
    runs-on: ubuntu-latest
    steps:
      - uses: southernlights-tech/retry-runner-loss-action@v1
        with:
          repo: ${{ github.repository }}
          run-id: ${{ github.event.workflow_run.id }}
          attempt: ${{ github.event.workflow_run.run_attempt }}
          pr-number: ${{ github.event.workflow_run.pull_requests[0].number }}
          run-url: ${{ github.event.workflow_run.html_url }}
```

The caller owns the `workflow_run` trigger and the watched-workflow allow-list,
and no `actions/checkout` is required: the action carries its own script, so no
untrusted PR code is executed.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `repo` | yes | — | `owner/name` of the repository. |
| `run-id` | yes | — | The workflow run id to inspect (`github.event.workflow_run.id`). |
| `attempt` | yes | — | The run attempt (`github.event.workflow_run.run_attempt`). |
| `max-attempts` | no | `"2"` | Maximum run attempts before the watchdog stops retrying. |
| `pr-number` | no | `""` | Pull request number to comment on when a retry is triggered (optional). |
| `run-url` | no | `""` | HTML URL of the triggering run, used in the notification comment (optional). |
| `mention` | no | `""` | Optional person or team to mention, e.g. `@octocat` or `@org/team`. A leading `@` is added if missing; empty means no mention. |
| `token` | no | `github.token` | Token used by the `gh` CLI. |

## Outputs

| Output | Description |
| --- | --- |
| `retried` | `'1'` when a retry was triggered, otherwise `'0'`. |

## Why a composite action

A composite action runs inside the caller's job, so the `workflow_run` trigger
and the watched-workflow allow-list stay with the caller. That trigger cannot
live in a called workflow: only a real workflow file in the watched repository
can subscribe to `workflow_run` events.

## Coverage guard (`/coverage` action)

The watched-workflow allow-list is an all-or-nothing safety property: a workflow
whose `name:` is not listed is never watched -- silently -- and a newly added
workflow is uncovered by default. `coverage/action.yml` is a second action path
in this repository that fails when a run-producing workflow is neither watched by
the watchdog nor explicitly excluded, so the allow-list cannot drift.

**Consumer-side by nature.** The guard reads *the caller's* workflow files, so
the caller MUST run `actions/checkout` first.

### Why a separate action path

The two actions have opposite requirements. The root action runs on
`workflow_run` in the base-branch context and must do so **without** checking out
untrusted code -- it carries its own script. The guard is useless without a
checkout and is meant to run in a plain `pull_request` job that needs nothing but
`contents: read`. Folding both into one `action.yml` would force the
`workflow_run` consumer to check out code, and would hide two very different
checkout/permission profiles behind one entry point.

Both actions ship as one release train: the `v1` tag covers
`southernlights-tech/retry-runner-loss-action@v1` and
`southernlights-tech/retry-runner-loss-action/coverage@v1` together, so the guard
and the action it guards can never drift apart by version.

### Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `watchdog` | yes | — | Path to the watchdog workflow that declares `on.workflow_run.workflows`. |
| `workflows-dir` | no | `.github/workflows` | Directory holding the repository's workflow files. |
| `excluded` | no | `""` | Newline-separated workflow `name:` values deliberately NOT watched. Each must resolve to a real workflow. |

### What it asserts

1. **Allow-list validity** -- every entry under `on.workflow_run.workflows:` in
   the watchdog matches a real workflow's top-level `name:`.
2. **No silent gaps** -- every run-producing workflow is either watched or
   listed in `excluded`. "Run-producing" is defined by inversion, not by an
   allow-list of known triggers: a workflow whose `on:` block carries at least
   one key other than `workflow_call`. Triggers such as `issue_comment`,
   `pull_request_review` or `release` are therefore covered automatically. A
   workflow whose `on:` block is missing, scalar/flow-form (`on: [push]`) or empty
   fails the guard **by name** instead of being skipped.
3. **Caller contract** -- scoped to the watchdog job that calls the action, so a
   decoy second job cannot satisfy it: `types: [completed]` (exactly, inside
   `on.workflow_run:`), a job gate testing both `conclusion == 'failure'` and
   `conclusion == 'cancelled'`, `runs-on: ubuntu-latest`, the four permission
   scopes (`contents: read`, `actions: write`, `pull-requests: write`,
   `checks: read`; workflow-level or job-level) and a step pinned to
   `southernlights-tech/retry-runner-loss-action@...`. If no job calls the
   action the guard fails.
4. **Stale-exclusion detection** -- every name in `excluded` must resolve to a
   real workflow `name:`, and no name may be both watched and excluded (a
   contradictory policy). Without this, a stale exclusion would silently mask a
   future workflow that reuses the name.

On success it prints one line:
`<N> workflow(s): <W> watched, <E> excluded, 0 gaps`.

### Usage

```yaml
jobs:
  coverage-guard:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v4
      - uses: southernlights-tech/retry-runner-loss-action/coverage@v1
        with:
          watchdog: .github/workflows/retry-on-runner-loss.yml
          excluded: |
            Retry on runner loss
```

The watchdog itself is run-producing (`workflow_run`), so it must appear in its
own allow-list or in `excluded` -- as in the example above.

Run the same check locally: `coverage/scripts/coverage-check.sh` with `WATCHDOG`
set (and optionally `WORKFLOWS_DIR` and `EXCLUDED`) in the environment.

## Development

```bash
docker run --rm -v "$PWD":/code -w /code bats/bats:latest tests/
docker run --rm -v "$PWD":/code -w /code bats/bats:latest coverage/tests/coverage-check.bats
shellcheck scripts/retry-runner-loss.sh
shellcheck coverage/scripts/coverage-check.sh
```
