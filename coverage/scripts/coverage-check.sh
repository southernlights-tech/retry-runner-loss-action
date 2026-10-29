#!/usr/bin/env bash
#
# coverage-check.sh — watchdog coverage guard (DEVOPS-1130).
#
# The runner-loss watchdog subscribes to a hard-coded ALLOW-LIST of workflow
# names via `on.workflow_run.workflows:`. A run-producing workflow whose `name:`
# is in no allow-list and is not explicitly excluded is SILENTLY unwatched: a
# self-hosted Spot reclaim kills its run and nothing re-runs it. A newly added
# workflow is uncovered by default, and a deleted/renamed workflow leaves a
# stale allow-list entry that silently matches nothing.
#
# This guard pins four things so the allow-list cannot drift silently:
#
#   (a) Allow-list validity — every entry under `on.workflow_run.workflows:` in
#       $WATCHDOG matches a real workflow's top-level `name:`.
#   (b) No silent gaps — every "run-producing" workflow is EITHER in the
#       watchdog allow-list OR named in $EXCLUDED. "Run-producing" is defined by
#       INVERSION, not by an allow-list of known triggers: a workflow is
#       run-producing iff its `on:` block exists and carries AT LEAST ONE key
#       other than `workflow_call` at the block's base indentation. Any trigger
#       emits runs a Spot reclaim can kill — push / pull_request / schedule /
#       workflow_dispatch / workflow_run, but equally issue_comment,
#       pull_request_review, pull_request_review_comment, release, merge_group,
#       etc. Workflows whose `on:` is `workflow_call`-only emit no runs of their
#       own and are skipped. A workflow with no parseable `on:` block (missing,
#       scalar/flow form such as `on: [push]`, or zero keys) FAILS the guard by
#       name rather than being skipped — a silent skip is how the original blind
#       spot arose.
#   (c) Caller contract — $WATCHDOG keeps the trigger, job gate, runner,
#       permissions and action ref the retry action requires.
#   (d) Stale-exclusion detection — every name in $EXCLUDED matches a real
#       workflow's top-level `name:`. A stale exclusion would otherwise mask a
#       future workflow that reuses the name. A name that is BOTH watched and
#       excluded is a contradictory policy and fails too.
#
# Consumer-side by nature: it reads the caller's workflow files, so the caller
# MUST check out the repository before invoking the composite action.
#
# Uses bash + coreutils + awk + sed/grep ONLY (no yq / jq / python).
#
# Environment:
#   WATCHDOG       (required) path to the watchdog workflow file
#   WORKFLOWS_DIR  (default: .github/workflows)
#   EXCLUDED       (default: "") newline-separated workflow `name:` values
#                  deliberately NOT watched

set -euo pipefail

watchdog="${WATCHDOG:-}"
workflows_dir="${WORKFLOWS_DIR:-.github/workflows}"
excluded_raw="${EXCLUDED:-}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Parsers (ported from gitops .github/bin/test_watchdog_coverage.sh)
# ---------------------------------------------------------------------------

# workflow_files — every workflow file, sorted, one path per line.
workflow_files() {
  find "${workflows_dir}" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) | sort
}

# top_level_name FILE — the first top-level `name:` value, with surrounding
# single/double quotes stripped (e.g. `name: "CSIT dev gate"` -> `CSIT dev gate`).
top_level_name() {
  awk '
    /^name:/ {
      v = $0; sub(/^name:[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
      print v; exit
    }
  ' "$1" | tr -d "\"'"
}

# allow_list FILE — the names under `on.workflow_run.workflows:`, one per line,
# quotes stripped. Scoped to the `workflows:` sub-block of `workflow_run:`.
allow_list() {
  awk '
    # Enter the workflow_run block, remembering its own indentation.
    /^[[:space:]]+workflow_run:[[:space:]]*$/ {
      in_wr = 1; in_wf = 0; match($0, /^[[:space:]]*/); wr_indent = RLENGTH; next
    }
    in_wr {
      # Blank / comment lines do not end the block.
      if ($0 ~ /^[[:space:]]*(#|$)/) next
      match($0, /^[[:space:]]*/); ind = RLENGTH
      # A line at or left of workflow_run is no longer inside it.
      if (ind <= wr_indent) { in_wr = 0; in_wf = 0; next }
      if ($0 ~ /^[[:space:]]+workflows:[[:space:]]*$/) { in_wf = 1; next }
      if (in_wf && $0 ~ /^[[:space:]]+types:/) { in_wf = 0; next }
    }
    # Items of the workflows: list, e.g. "      - Check Lint on PR".
    in_wf && /^[[:space:]]*-[[:space:]]+/ {
      v = $0; sub(/^[[:space:]]*-[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
      print v
    }
  ' "$1" | tr -d "\"'"
}

# on_block_keys FILE — the keys at the `on:` block's base indentation, one per
# line. Empty output means there is no parseable `on:` block: no `on:` key at
# all, a scalar/flow form such as `on: [push]`, or a block that yields no keys.
on_block_keys() {
  awk '
    BEGIN { in_on = 0; base = -1; n = 0 }
    # The top-level `on:` key (optionally double-quoted in YAML).
    /^["]?on["]?:[[:space:]]*$/ || /^["]?on["]?:[[:space:]]*#/ { in_on = 1; base = -1; next }
    in_on {
      if ($0 ~ /^[[:space:]]*(#|$)/) next          # blank / comment inside the block
      match($0, /^[[:space:]]*/); ind = RLENGTH
      if (base < 0) {
        if (ind <= 0) { in_on = 0; next }          # `on:` had no block -> outside
        base = ind
      }
      if (ind < base) { in_on = 0; next }          # left the block
      if (ind > base) next                         # nested key (types:, inputs:)
      line = substr($0, ind + 1)
      key = line; sub(/:.*/, "", key)
      if (key != "") { keys[++n] = key }
    }
    END { for (i = 1; i <= n; i++) print keys[i] }
  ' "$1"
}

# is_workflow_call_only FILE — true (exit 0) when the workflow's `on:` block is
# `workflow_call`-only. Collects the keys at the `on:` block's base indentation.
is_workflow_call_only() {
  local keys
  keys="$(on_block_keys "$1")"

  [ -n "${keys}" ] || return 1                     # no `on:` block keys -> not call-only
  # True only when EVERY base key is workflow_call and there is at least one.
  if printf '%s\n' "${keys}" | grep -qvx 'workflow_call'; then
    return 1
  fi
  return 0
}

# is_run_producing FILE — true (exit 0) when the `on:` block carries AT LEAST
# ONE key that is NOT `workflow_call`.
#
# This is deliberately the INVERSE of an allow-list of "known" triggers. An
# allow-list of push / pull_request / schedule / workflow_dispatch /
# workflow_run silently classified workflows fired by issue_comment,
# pull_request_review, pull_request_review_comment, issues, release,
# merge_group, ... as non-run-producing, so they escaped assertion (b). Any
# triggerable workflow running on the Spot pool can be reclaimed, so the
# predicate must be the complement of `workflow_call`-only.
#
# A file with no parseable `on:` block fails by name instead of being skipped:
# silently continuing is how the original blind spot arose.
is_run_producing() {
  local keys name note=""
  name="$(top_level_name "$1")"
  [ -z "${name}" ] || note=" (name: '${name}')"
  keys="$(on_block_keys "$1")"
  if [ -z "${keys}" ]; then
    fail "(b) $(basename "$1")${note} has no parseable \`on:\` block (missing, scalar/flow form, or zero keys) — refusing to skip it silently"
  fi
  printf '%s\n' "${keys}" | grep -qvx 'workflow_call'
}

# gate_block FILE — the text of every job-level `if:` value, in both the
# single-line form (`if: ${{ ... }}`) and the folded/literal block form
# (`if: >-` followed by indented continuation lines).
gate_block() {
  awk '
    /^[[:space:]]+if:[[:space:]]*/ {
      line = $0; sub(/^[[:space:]]+if:[[:space:]]*/, "", line)
      # Not a block scalar -> the whole condition is on this line.
      if (line !~ /^[>|][-+]?[[:space:]]*$/) { print line; next }
      match($0, /^[[:space:]]*/); base = RLENGTH; in_blk = 1; next
    }
    in_blk {
      if ($0 ~ /^[[:space:]]*(#|$)/) { print; next }
      match($0, /^[[:space:]]*/)
      if (RLENGTH <= base) { in_blk = 0; next }
      print
    }
  ' "$1"
}

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------
[ -n "${watchdog}" ] || fail "WATCHDOG is not set (path to the watchdog workflow that declares on.workflow_run.workflows)"
[ -f "${watchdog}" ] || fail "watchdog workflow not found: ${watchdog}"
[ -d "${workflows_dir}" ] || fail "workflows dir not found: ${workflows_dir}"

workflow_paths="$(workflow_files)"
[ -n "${workflow_paths}" ] || fail "no workflow files (*.yml/*.yaml) in ${workflows_dir}"

# All top-level names, one per line. A workflow with no `name:` contributes an
# empty line, which name_exists() can never match.
workflow_names=""
while IFS= read -r wf; do
  [ -n "${wf}" ] || continue
  workflow_names="${workflow_names}$(top_level_name "${wf}")"$'\n'
done <<< "${workflow_paths}"

# name_exists NAME — true when NAME is some workflow's top-level `name:`.
name_exists() {
  local needle="$1"
  [ -n "${needle}" ] || return 1
  printf '%s\n' "${workflow_names}" | grep -Fxq -e "${needle}"
}

allow="$(allow_list "${watchdog}")"
excluded="$(printf '%s\n' "${excluded_raw}" \
  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
  | grep -v '^$' || true)"

# ---------------------------------------------------------------------------
# Assertion (a): every allow-list entry names a real workflow.
# ---------------------------------------------------------------------------
[ -n "${allow}" ] || fail "(a) ${watchdog} has an empty workflow_run allow-list"

while IFS= read -r entry; do
  [ -n "${entry}" ] || continue
  if ! name_exists "${entry}"; then
    echo "  - allow-list entry '${entry}' matches no workflow's top-level name:" >&2
    fail "(a) watchdog allow-list names a workflow that does not exist"
  fi
done <<< "${allow}"

# ---------------------------------------------------------------------------
# Assertion (d): every exclusion names a real workflow, and no name is both
# watched and excluded.
# ---------------------------------------------------------------------------
if [ -n "${excluded}" ]; then
  while IFS= read -r entry; do
    [ -n "${entry}" ] || continue
    if ! name_exists "${entry}"; then
      echo "  - excluded entry '${entry}' matches no workflow's top-level name:" >&2
      fail "(d) EXCLUDED names a workflow that does not exist (stale exclusion)"
    fi
    if printf '%s\n' "${allow}" | grep -Fxq -e "${entry}"; then
      echo "  - '${entry}' is listed in the allow-list and in EXCLUDED:" >&2
      fail "contradictory policy: '${entry}' is both watched and excluded"
    fi
  done <<< "${excluded}"
fi

# ---------------------------------------------------------------------------
# Assertion (b): every run-producing workflow is watched or explicitly excluded.
# ---------------------------------------------------------------------------
gaps=0
while IFS= read -r wf; do
  [ -n "${wf}" ] || continue
  base="$(basename "${wf}")"
  if is_workflow_call_only "${wf}"; then
    continue
  fi
  if ! is_run_producing "${wf}"; then
    continue
  fi
  n="$(top_level_name "${wf}")"
  [ -n "${n}" ] || fail "(b) ${base} has no top-level \`name:\`"
  if printf '%s\n' "${allow}" | grep -Fxq -e "${n}"; then
    continue
  fi
  if [ -n "${excluded}" ] && printf '%s\n' "${excluded}" | grep -Fxq -e "${n}"; then
    continue
  fi
  echo "  - '${n}' (${base}) is run-producing but neither watched nor excluded" >&2
  gaps=$((gaps + 1))
done <<< "${workflow_paths}"

if [ "${gaps}" -ne 0 ]; then
  fail "(b) ${gaps} run-producing workflow(s) are silently unwatched — add each to the allow-list or to the \`excluded\` input of the coverage guard"
fi

# ---------------------------------------------------------------------------
# Assertion (c): watchdog caller contract.
# ---------------------------------------------------------------------------
# (c1) on.workflow_run.types is [completed].
grep -Eq '^[[:space:]]+types:[[:space:]]*\[completed\][[:space:]]*$' "${watchdog}" \
  || fail "(c) on.workflow_run.types must be [completed]"

# (c2) the job gate tests both failure and cancelled conclusions.
gate="$(gate_block "${watchdog}")"
printf '%s' "${gate}" | grep -Fq "github.event.workflow_run.conclusion == 'failure'" \
  || fail "(c) job gate does not test conclusion == 'failure'"
printf '%s' "${gate}" | grep -Fq "github.event.workflow_run.conclusion == 'cancelled'" \
  || fail "(c) job gate does not test conclusion == 'cancelled'"

# (c3) runs-on: ubuntu-latest (the watchdog must not run on the watched pool).
grep -Eq '^[[:space:]]+runs-on:[[:space:]]+ubuntu-latest[[:space:]]*$' "${watchdog}" \
  || fail "(c) runs-on must be ubuntu-latest"

# (c4) the four permission scopes the shared action requires.
for scope in 'contents: read' 'actions: write' 'pull-requests: write' 'checks: read'; do
  grep -Eq "^[[:space:]]+${scope}[[:space:]]*$" "${watchdog}" \
    || fail "(c) missing required permission: ${scope}"
done

# (c5) it calls the pinned shared action.
grep -Fq 'southernlights-tech/retry-runner-loss-action@' "${watchdog}" \
  || fail "(c) does not call southernlights-tech/retry-runner-loss-action@"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
workflow_count="$(printf '%s\n' "${workflow_paths}" | grep -c . || true)"
watched_count="$(printf '%s\n' "${allow}" | grep -c . || true)"
excluded_count=0
if [ -n "${excluded}" ]; then
  excluded_count="$(printf '%s\n' "${excluded}" | grep -c . || true)"
fi

echo "PASS: ${workflow_count} workflow(s): ${watched_count} watched, ${excluded_count} excluded, 0 gaps"
