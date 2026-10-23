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

## Coverage guard (consumer-side)

The watched-workflow allow-list is an all-or-nothing safety property: a workflow
whose `name:` is not listed is never watched -- silently -- and a newly added
workflow is uncovered by default. Keep a guard in the **consuming** repository
that fails when a run-producing workflow is neither watched nor explicitly
excluded, so the allow-list cannot drift. It cannot live in this action, which
has no visibility into the caller's workflows. (A reusable coverage check is a
possible later addition; it would require the caller to check out the default
branch.)

## Development

```bash
docker run --rm -v "$PWD":/code -w /code bats/bats:latest tests/
shellcheck scripts/retry-runner-loss.sh
```
