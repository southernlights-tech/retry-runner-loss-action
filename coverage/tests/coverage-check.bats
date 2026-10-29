#!/usr/bin/env bats

# Behavioural tests for coverage/scripts/coverage-check.sh (DEVOPS-1130).
#
# SELF-CONTAINED FIXTURES: every test builds a throwaway workflows directory in
# a temp dir and points the script at it through WATCHDOG / WORKFLOWS_DIR /
# EXCLUDED. Nothing here depends on this repository's own .github/workflows, so
# the suite stays green as the repo's workflows change.

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/coverage-check.sh"

setup() {
    FIXTURES="$(mktemp -d)"
    mkdir -p "${FIXTURES}/workflows"
    export WORKFLOWS_DIR="${FIXTURES}/workflows"
    export WATCHDOG="${WORKFLOWS_DIR}/retry-on-runner-loss.yml"
    unset EXCLUDED || true
    write_watchdog
    write_baseline_workflows
}

teardown() {
    rm -rf "${FIXTURES:-}"
}

# wf FILE — write stdin as a workflow file in the fixture directory.
wf() {
    cat > "${WORKFLOWS_DIR}/$1"
}

# write_watchdog — the valid caller contract; individual tests sed-mutate it.
write_watchdog() {
    cat > "${WATCHDOG}" <<'YAML'
name: Retry on runner loss
on:
  workflow_run:
    workflows:
      - Test
      - Deploy to Dev
      - Retry on runner loss
    types: [completed]
permissions:
  contents: read
  actions: write
  pull-requests: write
  checks: read
jobs:
  retry:
    if: >-
      ${{ github.event.workflow_run.conclusion == 'failure'
      || github.event.workflow_run.conclusion == 'cancelled' }}
    runs-on: ubuntu-latest
    steps:
      - uses: southernlights-tech/retry-runner-loss-action@v1
        with:
          repo: ${{ github.repository }}
YAML
}

# write_watchdog_single_line_gate — same contract, single-line `if:` form.
write_watchdog_single_line_gate() {
    cat > "${WATCHDOG}" <<'YAML'
name: Retry on runner loss
on:
  workflow_run:
    workflows:
      - Test
      - Deploy to Dev
      - Retry on runner loss
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
YAML
}

# write_baseline_workflows — the three workflows the default watchdog watches,
# plus one workflow_call-only reusable workflow (never a gap).
write_baseline_workflows() {
    wf test.yml <<'YAML'
name: Test
on:
  pull_request:
YAML
    wf deploy.yml <<'YAML'
name: Deploy to Dev
on:
  workflow_dispatch:
YAML
    wf reusable.yml <<'YAML'
name: Reusable
on:
  workflow_call:
YAML
}

# --- PASS cases -------------------------------------------------------------

@test "PASS: every workflow is watched or excluded" {
    run bash "${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"4 workflow(s)"* ]]
    [[ "$output" == *"3 watched"* ]]
    [[ "$output" == *"0 excluded, 0 gaps"* ]]
}

@test "PASS: an explicit exclusion satisfies the guard" {
    wf extra.yml <<'YAML'
name: Comment Bot
on:
  issue_comment:
YAML
    export EXCLUDED="Comment Bot"
    run bash "${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"5 workflow(s)"* ]]
    [[ "$output" == *"1 excluded, 0 gaps"* ]]
}

@test "PASS: a workflow_call-only workflow is not a gap" {
    wf reusable2.yml <<'YAML'
name: Reusable Only
on:
  workflow_call:
    inputs:
      foo:
        required: false
YAML
    run bash "${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 gaps"* ]]
}

@test "PASS (c): a single-line job gate is accepted" {
    # Guards the gate parser against only understanding the folded form.
    write_watchdog_single_line_gate
    run bash "${SCRIPT}"
    [ "$status" -eq 0 ]
}

# --- (a)/(c) parser robustness ----------------------------------------------

@test "PASS (a): a sibling list key does not leak phantom allow-list entries" {
    # A `branches:` list directly after `workflows:` must not be read as part of
    # the allow-list (it used to yield a phantom 'main' entry).
    cat > "${WATCHDOG}" <<'YAML'
name: Retry on runner loss
on:
  workflow_run:
    workflows:
      - Test
      - Deploy to Dev
      - Retry on runner loss
    branches:
      - main
    types: [completed]
permissions:
  contents: read
  actions: write
  pull-requests: write
  checks: read
jobs:
  retry:
    if: >-
      ${{ github.event.workflow_run.conclusion == 'failure'
      || github.event.workflow_run.conclusion == 'cancelled' }}
    runs-on: ubuntu-latest
    steps:
      - uses: southernlights-tech/retry-runner-loss-action@v1
YAML
    run bash "${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"3 watched"* ]]
    [[ "$output" != *"main"* ]]
}

@test "PASS (a): flow-style on.workflow_run.workflows parses every entry" {
    # `workflows: [A, B, C]` used to report an empty allow-list.
    sed -i \
        -e 's|^    workflows:$|    workflows: [Test, Deploy to Dev, Retry on runner loss]|' \
        -e '/^      - Test$/d' \
        -e '/^      - Deploy to Dev$/d' \
        -e '/^      - Retry on runner loss$/d' \
        "${WATCHDOG}"
    run bash "${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"3 watched"* ]]
    [[ "$output" == *"0 excluded, 0 gaps"* ]]
}

@test "PASS: an exclusion keeps interior quotes (true name, not mutilated)" {
    # `tr -d "\"'"` used to turn `Don't deploy yet` into `Dont deploy yet`, so
    # only the mutilated spelling satisfied the guard.
    wf apostrophe.yml <<'YAML'
name: Don't deploy yet
on:
  pull_request:
YAML
    export EXCLUDED="Don't deploy yet"
    run bash "${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"5 workflow(s)"* ]]
    [[ "$output" == *"1 excluded, 0 gaps"* ]]
}

@test "PASS: a multi-line EXCLUDED list honours every name" {
    wf one.yml <<'YAML'
name: One
on:
  push:
YAML
    wf two.yml <<'YAML'
name: Two
on:
  schedule:
YAML
    export EXCLUDED="One
Two"
    run bash "${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"6 workflow(s)"* ]]
    [[ "$output" == *"2 excluded, 0 gaps"* ]]
}

# --- (a) allow-list validity ------------------------------------------------

@test "FAIL (a): a typo'd allow-list entry resolves to nothing" {
    sed -i 's/^      - Test$/      - Tset/' "${WATCHDOG}"
    run bash "${SCRIPT}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"allow-list entry 'Tset' matches no workflow"* ]]
    [[ "$output" == *"(a) watchdog allow-list names a workflow that does not exist"* ]]
}

# --- (b) no silent gaps -----------------------------------------------------

@test "FAIL (b): a run-producing workflow neither watched nor excluded" {
    wf lint.yml <<'YAML'
name: Lint
on:
  pull_request:
YAML
    run bash "${SCRIPT}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"'Lint' (lint.yml) is run-producing but neither watched nor excluded"* ]]
    [[ "$output" == *"(b) 1 run-producing workflow(s) are silently unwatched"* ]]
}

@test "FAIL (b): a workflow triggered only on issue_comment is a gap" {
    # The exact blind spot: an allow-list of "known" triggers would classify
    # this as non-run-producing and skip it silently.
    wf comment.yml <<'YAML'
name: Comment Bot
on:
  issue_comment:
    types: [created]
YAML
    run bash "${SCRIPT}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"'Comment Bot' (comment.yml) is run-producing"* ]]
}

@test "FAIL (b): a workflow triggered only on merge_group is a gap" {
    # An exotic trigger must still count as run-producing: the predicate is the
    # complement of workflow_call-only, not an allow-list of known triggers.
    wf merge.yml <<'YAML'
name: Merge Queue
on:
  merge_group:
YAML
    run bash "${SCRIPT}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"'Merge Queue' (merge.yml) is run-producing"* ]]
    [[ "$output" == *"(b) 1 run-producing workflow(s) are silently unwatched"* ]]
}

@test "FAIL (b): a mixed trigger (push + workflow_call) is run-producing" {
    wf mixed.yml <<'YAML'
name: Mixed
on:
  push:
  workflow_call:
YAML
    run bash "${SCRIPT}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"'Mixed' (mixed.yml) is run-producing"* ]]
}

@test "FAIL (b): scalar/flow form 'on: [push]' fails by name" {
    wf scalar.yml <<'YAML'
name: Scalar
on: [push]
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - run: "true"
YAML
    run bash "${SCRIPT}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"scalar.yml (name: 'Scalar') has no parseable \`on:\` block"* ]]
}

@test "FAIL (b): a missing 'on:' block fails by name" {
    wf no-on.yml <<'YAML'
name: No On
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - run: "true"
YAML
    run bash "${SCRIPT}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no-on.yml (name: 'No On') has no parseable \`on:\` block"* ]]
}

# --- (c) caller contract ----------------------------------------------------

@test "FAIL (c): missing permission contents: read" {
    sed -i '/^  contents: read$/d' "${WATCHDOG}"
    run bash "${SCRIPT}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"(c) missing required permission: contents: read"* ]]
}

@test "FAIL (c): missing permission actions: write" {
    sed -i '/^  actions: write$/d' "${WATCHDOG}"
    run bash "${SCRIPT}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"(c) missing required permission: actions: write"* ]]
}

@test "FAIL (c): missing permission pull-requests: write" {
    sed -i '/^  pull-requests: write$/d' "${WATCHDOG}"
    run bash "${SCRIPT}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"(c) missing required permission: pull-requests: write"* ]]
}

@test "FAIL (c): missing permission checks: read" {
    sed -i '/^  checks: read$/d' "${WATCHDOG}"
    run bash "${SCRIPT}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"(c) missing required permission: checks: read"* ]]
}

@test "FAIL (c): workflow_run types must be [completed]" {
    sed -i 's/^    types: \[completed\]$/    types: [requested]/' "${WATCHDOG}"
    run bash "${SCRIPT}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"(c) on.workflow_run.types must be [completed]"* ]]
}

@test "FAIL (c): an unrelated types: [completed] does not satisfy workflow_run" {
    # The check must read `types:` INSIDE on.workflow_run, and must reject a
    # superset. Here workflow_run asks for [completed, requested] while a
    # workflow_dispatch block carries the tempting `types: [completed]`.
    cat > "${WATCHDOG}" <<'YAML'
name: Retry on runner loss
on:
  workflow_run:
    workflows:
      - Test
      - Deploy to Dev
      - Retry on runner loss
    types: [completed, requested]
  workflow_dispatch:
    types: [completed]
permissions:
  contents: read
  actions: write
  pull-requests: write
  checks: read
jobs:
  retry:
    if: >-
      ${{ github.event.workflow_run.conclusion == 'failure'
      || github.event.workflow_run.conclusion == 'cancelled' }}
    runs-on: ubuntu-latest
    steps:
      - uses: southernlights-tech/retry-runner-loss-action@v1
YAML
    run bash "${SCRIPT}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"(c) on.workflow_run.types must be [completed]"* ]]
}

@test "FAIL (c): job gate must test conclusion == 'failure'" {
    sed -i "s/== 'failure'/== 'timed_out'/" "${WATCHDOG}"
    run bash "${SCRIPT}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"(c) job gate does not test conclusion == 'failure'"* ]]
}

@test "FAIL (c): job gate must test conclusion == 'cancelled'" {
    sed -i "s/== 'cancelled'/== 'skipped'/" "${WATCHDOG}"
    run bash "${SCRIPT}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"(c) job gate does not test conclusion == 'cancelled'"* ]]
}

@test "FAIL (c): runs-on must be ubuntu-latest" {
    sed -i 's/^    runs-on: ubuntu-latest$/    runs-on: self-hosted/' "${WATCHDOG}"
    run bash "${SCRIPT}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"(c) runs-on must be ubuntu-latest"* ]]
}

@test "FAIL (c): a decoy second job cannot satisfy the contract" {
    # The real retry job is self-hosted and gates only on 'failure'. A decoy
    # 'notify' job has ubuntu-latest and the full gate. Assertion (c) must read
    # ONLY the job that calls the action, so this must FAIL on the retry job's
    # missing 'cancelled' arm (and never see the decoy).
    cat > "${WATCHDOG}" <<'YAML'
name: Retry on runner loss
on:
  workflow_run:
    workflows:
      - Test
      - Deploy to Dev
      - Retry on runner loss
    types: [completed]
permissions:
  contents: read
  actions: write
  pull-requests: write
  checks: read
jobs:
  retry:
    if: >-
      ${{ github.event.workflow_run.conclusion == 'failure' }}
    runs-on: self-hosted
    steps:
      - uses: southernlights-tech/retry-runner-loss-action@v1
  notify:
    if: >-
      ${{ github.event.workflow_run.conclusion == 'failure'
      || github.event.workflow_run.conclusion == 'cancelled' }}
    runs-on: ubuntu-latest
    steps:
      - run: echo "decoy"
YAML
    run bash "${SCRIPT}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"(c)"* ]]
    [[ "$output" == *"cancelled"* ]]
}

@test "FAIL (c): must call the pinned retry action" {
    sed -i 's#southernlights-tech/retry-runner-loss-action@v1#some-other/action@v1#' "${WATCHDOG}"
    run bash "${SCRIPT}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"(c) does not call southernlights-tech/retry-runner-loss-action@"* ]]
}

# --- (d) stale exclusion / contradictory policy -----------------------------

@test "FAIL (d): an exclusion name that matches no workflow" {
    export EXCLUDED="Removed Workflow"
    run bash "${SCRIPT}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"excluded entry 'Removed Workflow' matches no workflow"* ]]
    [[ "$output" == *"(d) EXCLUDED names a workflow that does not exist (stale exclusion)"* ]]
}

@test "FAIL: a name both watched and excluded" {
    export EXCLUDED="Test"
    run bash "${SCRIPT}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"'Test' is listed in the allow-list and in EXCLUDED"* ]]
    [[ "$output" == *"contradictory policy"* ]]
}

# --- input validation -------------------------------------------------------

@test "FAIL: WATCHDOG is required" {
    unset WATCHDOG
    run bash "${SCRIPT}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"WATCHDOG is not set"* ]]
}

@test "FAIL: a missing workflows directory is reported" {
    export WORKFLOWS_DIR="${FIXTURES}/does-not-exist"
    run bash "${SCRIPT}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"workflows dir not found"* ]]
}
