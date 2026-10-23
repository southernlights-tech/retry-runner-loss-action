#!/bin/bash

# Decide whether a failed/cancelled workflow run was killed by self-hosted
# runner loss (e.g. an EC2 Spot reclaim) and, if so, re-run it.
#
# Sourced by action.yml (the composite action) and covered by
# tests/retry-runner-loss.bats. Tracked by DEVOPS-895 / DEVOPS-908 /
# DEVOPS-990.
#
# Requires an authenticated `gh` CLI (GH_TOKEN) plus grep/mktemp.
#
# Sets the global RETRY_PERFORMED to 1 when it triggers a re-run (0 otherwise);
# the workflow surfaces that as the `retried` step output. This function never
# fails the calling step: problems are reported as ::warning:: annotations so
# they appear in the Actions UI without turning the watchdog red.

# Graceful drain: the runner printed this to its log before exiting. This is the
# signal that fires in practice -- it was present on 5/5 of the runner-loss
# events sampled for DEVOPS-990.
RUNNER_LOSS_SIGNATURE="The runner has received a shutdown signal"

# Abrupt loss: the runner vanished without printing anything, so GitHub attaches
# this check-run annotation instead of a log. Deliberately specific -- the
# generic "The operation was canceled." annotation is NOT matched here, because
# a human-cancelled run carries it too, and auto-retrying a deliberate
# cancellation would be worse than the bug this fixes.
RUNNER_LOST_COMMS_SIGNATURE="lost communication with the server"

# Set to 1 by retry_run_on_runner_loss when it triggers a re-run.
export RETRY_PERFORMED=0

# retry_run_on_runner_loss <repo> <run_id> <attempt> [max_attempts]
#
# Re-runs <run_id> only when a failed or cancelled job shows runner loss. Always
# returns 0; the fail-safe default is to NOT retry.
retry_run_on_runner_loss() {
    local repo="$1"
    local run_id="$2"
    local attempt="$3"
    local max_attempts="${4:-2}"

    RETRY_PERFORMED=0

    if [ "${attempt}" -ge "${max_attempts}" ]; then
        echo "run attempt ${attempt} >= max_attempts ${max_attempts}; not retrying."
        return 0
    fi

    # A job killed by runner loss ends `cancelled` on a graceful drain but
    # `failure` when the runner dies mid-job -- which is the common case
    # (DEVOPS-990: 4 of the 5 observed kills concluded `failure`). Consider both,
    # and report a failed enumeration explicitly, so that "could not list jobs"
    # is never indistinguishable from "nothing matched".
    local jobs errfile
    if ! errfile="$(mktemp)"; then
        echo "::warning::retry-runner-loss: could not create a temp file; not retrying."
        return 0
    fi
    if ! jobs="$(gh run view "${run_id}" --repo "${repo}" --json jobs \
        --jq '.jobs[] | select(.conclusion == "failure" or .conclusion == "cancelled") | .databaseId' \
        2>"${errfile}")"; then
        echo "::warning::retry-runner-loss: Could not list jobs for run ${run_id}; not retrying. gh said: $(tr '\n' ' ' <"${errfile}" | cut -c1-500)"
        rm -f "${errfile}"
        return 0
    fi
    rm -f "${errfile}"

    if [ -z "${jobs}" ]; then
        echo "No failed or cancelled jobs in run ${run_id}; not retrying."
        return 0
    fi

    local job_id logfile annotations log_ok
    while IFS= read -r job_id; do
        [ -n "${job_id}" ] || continue

        # Primary signal: the shutdown signature in the job log. A readable log
        # is authoritative -- if it holds no signature we move on and do NOT
        # consult the annotation fallback, so an ambiguous annotation can never
        # turn a genuine failure into a retry.
        if ! logfile="$(mktemp)"; then
            echo "::warning::retry-runner-loss: could not create a temp file; not retrying."
            return 0
        fi
        if ! errfile="$(mktemp)"; then
            rm -f "${logfile}"
            echo "::warning::retry-runner-loss: could not create a temp file; not retrying."
            return 0
        fi
        # DEVOPS-1029: a SUCCESSFUL fetch can still yield an empty body -- observed
        # in production (run 39438234059 / job 118681803685), where the blob did
        # contain the signature but the fetch returned nothing, and the run was
        # silently not retried. An empty body is not evidence of absence: treat it
        # as unavailable and fall through to the annotation path below.
        local log_ok=0
        if gh run view "${run_id}" --repo "${repo}" --job "${job_id}" --log >"${logfile}" 2>"${errfile}"; then
            log_ok=1
        fi

        if [ "${log_ok}" -eq 1 ] && [ -s "${logfile}" ]; then
            rm -f "${errfile}"
            if grep -qF "${RUNNER_LOSS_SIGNATURE}" "${logfile}"; then
                rm -f "${logfile}"
                echo "Runner-shutdown signature on job ${job_id}; re-running run ${run_id} (attempt ${attempt} -> $((attempt + 1)))."
                RETRY_PERFORMED=1
                if ! gh run rerun "${run_id}" --repo "${repo}"; then
                    echo "::warning::retry-runner-loss: 'gh run rerun' failed for run ${run_id}; the run was NOT retried."
                    RETRY_PERFORMED=0
                fi
                return 0
            fi
            rm -f "${logfile}"
            echo "Job ${job_id}: log readable, no runner-shutdown signature; not consulting annotations."
            continue
        fi

        # Fallback signal, reachable only when the log could not be read at all.
        # Keep the two failure modes distinguishable in the log: a failed fetch
        # (non-zero exit) versus a successful fetch that returned an empty body.
        if [ "${log_ok}" -eq 1 ]; then
            echo "::warning::retry-runner-loss: Job ${job_id}: log fetch succeeded but returned an empty body; treating as unavailable; checking check-run annotations."
        else
            echo "::warning::retry-runner-loss: Job ${job_id}: log unavailable ($(tr '\n' ' ' <"${errfile}" | cut -c1-300)); checking check-run annotations."
        fi
        rm -f "${logfile}" "${errfile}"

        if ! errfile="$(mktemp)"; then
            echo "::warning::retry-runner-loss: could not create a temp file; not retrying."
            return 0
        fi
        if ! annotations="$(gh api "repos/${repo}/check-runs/${job_id}/annotations" \
            --jq '.[].message' 2>"${errfile}")"; then
            echo "::warning::retry-runner-loss: Job ${job_id}: could not fetch check-run annotations; not retrying. gh said: $(tr '\n' ' ' <"${errfile}" | cut -c1-300)"
            rm -f "${errfile}"
            continue
        fi
        rm -f "${errfile}"
        if printf '%s' "${annotations}" | grep -qiF "${RUNNER_LOST_COMMS_SIGNATURE}"; then
            echo "Runner-lost-communication annotation on job ${job_id}; re-running run ${run_id} (attempt ${attempt} -> $((attempt + 1)))."
            RETRY_PERFORMED=1
            if ! gh run rerun "${run_id}" --repo "${repo}"; then
                echo "::warning::retry-runner-loss: 'gh run rerun' failed for run ${run_id}; the run was NOT retried."
                RETRY_PERFORMED=0
            fi
            return 0
        fi
        echo "Job ${job_id}: no runner-loss annotation."
    done <<< "${jobs}"

    echo "No runner-loss evidence in failed/cancelled jobs of run ${run_id}; not retrying."
    return 0
}
