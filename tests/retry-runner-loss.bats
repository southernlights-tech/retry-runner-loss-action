#!/usr/bin/env bats

# Behavioral tests for scripts/retry-runner-loss.sh.
# Stubs `gh` on a temp PATH so no API calls are made.

SCRIPT="scripts/retry-runner-loss.sh"
SIGNATURE="The runner has received a shutdown signal"
LOST_COMMS="lost communication with the server"

setup() {
    FAKE_BIN="$(mktemp -d)"
    export PATH="$FAKE_BIN:$PATH"
    export RERUN_MARKER="$FAKE_BIN/rerun-called"

    # Stub `gh`. The test controls behaviour via exported env vars:
    #   STUB_JOBS        output of `gh run view ... --json jobs --jq ...`
    #                    (newline-separated failed/cancelled job ids)
    #   STUB_JOBS_FAIL   when "1", the job listing exits non-zero
    #   STUB_LOG         output of `gh run view ... --job ... --log`
    #   STUB_LOG_FAIL    when "1", the per-job log fetch exits non-zero
    #   STUB_LOG_EMPTY   when "1", the log fetch SUCCEEDS but writes an empty body
    #   STUB_LOG_DIR    when set, `--job <id>` returns the file <dir>/<id>
    #   STUB_ANNOTATIONS output of `gh api .../check-runs/<id>/annotations`
    #   STUB_ANNOTATIONS_FAIL  when "1", the annotations fetch exits non-zero
    #   STUB_RERUN_FAIL  when "1", `gh run rerun` exits non-zero
    #   STUB_QUERY_FILE  when set, records the args of the job-listing call
    cat > "$FAKE_BIN/gh" <<'STUB'
#!/usr/bin/env bash
# gh run rerun ...
if [ "${1:-}" = "run" ] && [ "${2:-}" = "rerun" ]; then
    if [ "${STUB_RERUN_FAIL:-0}" = "1" ]; then
        echo "HTTP 403: Forbidden" >&2
        exit 1
    fi
    touch "$RERUN_MARKER"
    exit 0
fi
# gh api repos/<owner>/<repo>/check-runs/<id>/annotations ...
if [ "${1:-}" = "api" ]; then
    if [ "${STUB_ANNOTATIONS_FAIL:-0}" = "1" ]; then
        echo "HTTP 404: Not Found" >&2
        exit 1
    fi
    printf '%s\n' "${STUB_ANNOTATIONS:-}"
    exit 0
fi
# gh run view <id> ...
if [ "${1:-}" = "run" ] && [ "${2:-}" = "view" ]; then
    job_id=""
    prev=""
    for arg in "$@"; do
        if [ "$prev" = "--job" ]; then
            job_id="$arg"
        fi
        prev="$arg"
    done
    if [ -n "$job_id" ]; then
        if [ "${STUB_LOG_FAIL:-0}" = "1" ]; then
            echo "no logs retained for this job" >&2
            exit 1
        fi
        if [ "${STUB_LOG_EMPTY:-0}" = "1" ]; then
            exit 0
        fi
        # Per-job logs let a test model a multi-job run where the first job is a
        # genuine failure and a later job was runner-killed.
        if [ -n "${STUB_LOG_DIR:-}" ]; then
            if [ -f "${STUB_LOG_DIR}/${job_id}" ]; then
                cat "${STUB_LOG_DIR}/${job_id}"
            fi
            exit 0
        fi
        printf '%s\n' "${STUB_LOG:-}"
        exit 0
    fi
    if [ -n "${STUB_QUERY_FILE:-}" ]; then
        printf '%s\n' "$*" > "$STUB_QUERY_FILE"
    fi
    if [ "${STUB_JOBS_FAIL:-0}" = "1" ]; then
        echo "run not found" >&2
        exit 1
    fi
    printf '%s\n' "${STUB_JOBS:-}"
    exit 0
fi
exit 1
STUB
    chmod +x "$FAKE_BIN/gh"
}

teardown() {
    rm -rf "${FAKE_BIN:-}"
}

# Installs a `mktemp` stub on the fake PATH that fails on the Nth invocation and
# otherwise delegates to the real mktemp. Lets each guarded mktemp site be
# exercised independently. Requires STUB_MKTEMP_COUNT_FILE and
# STUB_MKTEMP_FAIL_ON to be exported by the test.
write_mktemp_stub() {
    cat > "$FAKE_BIN/mktemp" <<'STUBMKTEMP'
#!/usr/bin/env bash
count_file="${STUB_MKTEMP_COUNT_FILE:?STUB_MKTEMP_COUNT_FILE must be set}"
fail_on="${STUB_MKTEMP_FAIL_ON:?STUB_MKTEMP_FAIL_ON must be set}"
n=0
if [ -f "$count_file" ]; then n="$(cat "$count_file")"; fi
n=$((n + 1))
printf '%s' "$n" > "$count_file"
if [ "$n" = "$fail_on" ]; then
    echo "mktemp: cannot create temp file" >&2
    exit 1
fi
# Delegate to the real mktemp, skipping this stub's own directory.
self_dir="$(cd "$(dirname "$0")" && pwd)"
IFS=: read -r -a parts <<< "$PATH"
for p in "${parts[@]}"; do
    [ "$p" = "$self_dir" ] && continue
    if [ -x "$p/mktemp" ]; then exec "$p/mktemp" "$@"; fi
done
echo "mktemp: could not locate the real mktemp" >&2
exit 1
STUBMKTEMP
    chmod +x "$FAKE_BIN/mktemp"
}

# --- pre-existing behaviour -------------------------------------------------

@test "signature present -> rerun invoked" {
    export STUB_JOBS="123"
    export STUB_LOG="$SIGNATURE"
    source "$SCRIPT"
    run retry_run_on_runner_loss "o/r" "999" "1" "2"
    [ "$status" -eq 0 ]
    [ -f "$RERUN_MARKER" ]
}

@test "no failed or cancelled jobs -> no rerun" {
    export STUB_JOBS=""
    source "$SCRIPT"
    run retry_run_on_runner_loss "o/r" "999" "1" "2"
    [ "$status" -eq 0 ]
    [ ! -f "$RERUN_MARKER" ]
}

@test "readable log without signature -> no rerun" {
    export STUB_JOBS="123"
    export STUB_LOG="some other failure output"
    source "$SCRIPT"
    run retry_run_on_runner_loss "o/r" "999" "1" "2"
    [ "$status" -eq 0 ]
    [ ! -f "$RERUN_MARKER" ]
}

@test "attempt >= max_attempts -> no rerun even with signature" {
    export STUB_JOBS="123"
    export STUB_LOG="$SIGNATURE"
    source "$SCRIPT"
    run retry_run_on_runner_loss "o/r" "999" "2" "2"
    [ "$status" -eq 0 ]
    [ ! -f "$RERUN_MARKER" ]
}

@test "rerun sets RETRY_PERFORMED=1" {
    export STUB_JOBS="123"
    export STUB_LOG="$SIGNATURE"
    source "$SCRIPT"
    retry_run_on_runner_loss "o/r" "999" "1" "2" >/dev/null
    [ "$RETRY_PERFORMED" -eq 1 ]
}

@test "no rerun leaves RETRY_PERFORMED=0" {
    export STUB_JOBS=""
    source "$SCRIPT"
    retry_run_on_runner_loss "o/r" "999" "1" "2" >/dev/null
    [ "$RETRY_PERFORMED" -eq 0 ]
}

# --- DEVOPS-990: job selection ----------------------------------------------

@test "AC1: job query selects failure and cancelled conclusions" {
    export STUB_JOBS=""
    export STUB_QUERY_FILE="$FAKE_BIN/query"
    source "$SCRIPT"
    run retry_run_on_runner_loss "o/r" "999" "1" "2"
    [ -f "$STUB_QUERY_FILE" ]
    run grep -F 'select(.conclusion == "failure" or .conclusion == "cancelled")' "$STUB_QUERY_FILE"
    [ "$status" -eq 0 ]
}

# --- DEVOPS-990: annotation fallback is bounded ------------------------------

@test "AC2: log unavailable + lost-communication annotation -> rerun" {
    export STUB_JOBS="123"
    export STUB_ANNOTATIONS="$LOST_COMMS"
    export STUB_LOG_FAIL="1"
    source "$SCRIPT"
    run retry_run_on_runner_loss "o/r" "999" "1" "2"
    [ "$status" -eq 0 ]
    [ -f "$RERUN_MARKER" ]
}

@test "AC2: log unavailable + unrelated annotation -> no rerun" {
    export STUB_JOBS="123"
    export STUB_ANNOTATIONS="some other annotation"
    export STUB_LOG_FAIL="1"
    source "$SCRIPT"
    run retry_run_on_runner_loss "o/r" "999" "1" "2"
    [ "$status" -eq 0 ]
    [ ! -f "$RERUN_MARKER" ]
}

@test "AC2 guard: readable log without signature ignores annotations entirely" {
    # The critical false-positive guard: a human-cancelled or genuinely failing
    # run has a readable log, so the annotation must never be consulted.
    export STUB_JOBS="123"
    export STUB_LOG="some other failure output"
    export STUB_ANNOTATIONS="$LOST_COMMS"
    source "$SCRIPT"
    run retry_run_on_runner_loss "o/r" "999" "1" "2"
    [ "$status" -eq 0 ]
    [ ! -f "$RERUN_MARKER" ]
    [[ "$output" == *"not consulting annotations"* ]]
}

@test "AC2 guard: the generic cancellation annotation is never matched" {
    export STUB_JOBS="123"
    export STUB_ANNOTATIONS="The operation was canceled."
    export STUB_LOG_FAIL="1"
    source "$SCRIPT"
    run retry_run_on_runner_loss "o/r" "999" "1" "2"
    [ "$status" -eq 0 ]
    [ ! -f "$RERUN_MARKER" ]
}

# --- DEVOPS-990: fail-safe and error visibility ------------------------------

@test "AC3: log unavailable and no annotation -> no rerun (fail safe)" {
    export STUB_JOBS="123"
    export STUB_LOG_FAIL="1"
    source "$SCRIPT"
    run retry_run_on_runner_loss "o/r" "999" "1" "2"
    [ "$status" -eq 0 ]
    [ ! -f "$RERUN_MARKER" ]
}

@test "AC3: max_attempts still caps the annotation path" {
    export STUB_JOBS="123"
    export STUB_ANNOTATIONS="$LOST_COMMS"
    export STUB_LOG_FAIL="1"
    source "$SCRIPT"
    run retry_run_on_runner_loss "o/r" "999" "2" "2"
    [ "$status" -eq 0 ]
    [ ! -f "$RERUN_MARKER" ]
}

@test "AC4: log fetch failure is reported, not swallowed" {
    export STUB_JOBS="123"
    export STUB_LOG_FAIL="1"
    source "$SCRIPT"
    run retry_run_on_runner_loss "o/r" "999" "1" "2"
    [ "$status" -eq 0 ]
    [[ "$output" == *"log unavailable"* ]]
    [[ "$output" == *"no logs retained for this job"* ]]
}

@test "AC4: job listing failure is reported, not swallowed" {
    export STUB_JOBS_FAIL="1"
    source "$SCRIPT"
    run retry_run_on_runner_loss "o/r" "999" "1" "2"
    [ "$status" -eq 0 ]
    [ ! -f "$RERUN_MARKER" ]
    [[ "$output" == *"Could not list jobs"* ]]
    [[ "$output" == *"run not found"* ]]
}

@test "AC5: a failed 'gh run rerun' does not fail the step and clears RETRY_PERFORMED" {
    export STUB_JOBS="123"
    export STUB_LOG="$SIGNATURE"
    export STUB_RERUN_FAIL="1"
    source "$SCRIPT"
    retry_run_on_runner_loss "o/r" "999" "1" "2" >/dev/null
    [ "$?" -eq 0 ]
    [ "$RETRY_PERFORMED" -eq 0 ]
}

@test "AC4: annotation fetch failure is reported, not swallowed" {
    export STUB_JOBS="123"
    export STUB_LOG_FAIL="1"
    export STUB_ANNOTATIONS_FAIL="1"
    source "$SCRIPT"
    run retry_run_on_runner_loss "o/r" "999" "1" "2"
    [ "$status" -eq 0 ]
    [ ! -f "$RERUN_MARKER" ]
    [[ "$output" == *"could not fetch check-run annotations"* ]]
    [[ "$output" == *"HTTP 404: Not Found"* ]]
}

@test "AC5: a failed 'gh run rerun' on the annotation path does not fail the step and clears RETRY_PERFORMED" {
    export STUB_JOBS="123"
    export STUB_ANNOTATIONS="$LOST_COMMS"
    export STUB_LOG_FAIL="1"
    export STUB_RERUN_FAIL="1"
    source "$SCRIPT"
    retry_run_on_runner_loss "o/r" "999" "1" "2" >/dev/null
    [ "$?" -eq 0 ]
    [ "$RETRY_PERFORMED" -eq 0 ]
    [ ! -f "$RERUN_MARKER" ]
}

@test "scan continues past a genuine failure to a later runner-loss job" {
    # The shape of every real multi-job Test run: an earlier job failed for a
    # genuine reason and a later job was killed by runner loss. Guards the loop's
    # `continue` -- if it regressed to `return 0`, the runner-loss job would be
    # silently skipped.
    export STUB_JOBS="123
456"
    export STUB_LOG_DIR="$FAKE_BIN/logs"
    mkdir -p "$STUB_LOG_DIR"
    printf '%s\n' "genuine failure output" > "$STUB_LOG_DIR/123"
    printf '%s\n' "$SIGNATURE" > "$STUB_LOG_DIR/456"
    source "$SCRIPT"
    run retry_run_on_runner_loss "o/r" "999" "1" "2"
    [ "$status" -eq 0 ]
    [ -f "$RERUN_MARKER" ]
    [[ "$output" == *"Job 123: log readable, no runner-shutdown signature"* ]]
    [[ "$output" == *"Runner-shutdown signature on job 456"* ]]
}

@test "mktemp failure does not fail the step and does not retry" {
    # Shadow mktemp so the guard at the top of the function is exercised.
    cat > "$FAKE_BIN/mktemp" <<'STUBMKTEMP'
#!/usr/bin/env bash
echo "mktemp: cannot create temp file" >&2
exit 1
STUBMKTEMP
    chmod +x "$FAKE_BIN/mktemp"
    export STUB_JOBS="123"
    export STUB_LOG="$SIGNATURE"
    source "$SCRIPT"
    run retry_run_on_runner_loss "o/r" "999" "1" "2"
    [ "$status" -eq 0 ]
    [ ! -f "$RERUN_MARKER" ]
    [[ "$output" == *"could not create a temp file"* ]]
}

@test "mktemp failure at the per-job logfile guard (site 2) does not fail the step and does not retry" {
    export STUB_JOBS="123"
    export STUB_LOG="$SIGNATURE"
    export STUB_MKTEMP_COUNT_FILE="$FAKE_BIN/mktemp-count"
    # call 1 = top-of-function errfile, call 2 = per-job logfile
    export STUB_MKTEMP_FAIL_ON="2"
    write_mktemp_stub
    source "$SCRIPT"
    run retry_run_on_runner_loss "o/r" "999" "1" "2"
    [ "$status" -eq 0 ]
    [ ! -f "$RERUN_MARKER" ]
    [[ "$output" == *"could not create a temp file"* ]]
}

@test "mktemp failure at the per-job errfile guard (site 3) does not fail the step and does not retry" {
    export STUB_JOBS="123"
    export STUB_LOG="$SIGNATURE"
    export STUB_MKTEMP_COUNT_FILE="$FAKE_BIN/mktemp-count"
    # call 1 = top-of-function errfile, 2 = per-job logfile, 3 = per-job errfile
    export STUB_MKTEMP_FAIL_ON="3"
    write_mktemp_stub
    source "$SCRIPT"
    run retry_run_on_runner_loss "o/r" "999" "1" "2"
    [ "$status" -eq 0 ]
    [ ! -f "$RERUN_MARKER" ]
    [[ "$output" == *"could not create a temp file"* ]]
}

@test "mktemp failure at the annotation-fallback errfile guard (site 4) does not fail the step and does not retry" {
    export STUB_JOBS="123"
    # Log fetch fails so execution reaches the annotation-fallback block.
    export STUB_LOG_FAIL="1"
    export STUB_MKTEMP_COUNT_FILE="$FAKE_BIN/mktemp-count"
    # call 1 = top-of-function errfile, 2 = per-job logfile, 3 = per-job errfile,
    # 4 = annotation-fallback errfile
    export STUB_MKTEMP_FAIL_ON="4"
    write_mktemp_stub
    source "$SCRIPT"
    run retry_run_on_runner_loss "o/r" "999" "1" "2"
    [ "$status" -eq 0 ]
    [ ! -f "$RERUN_MARKER" ]
    [[ "$output" == *"could not create a temp file"* ]]
}

@test "AC1: an empty log body falls through to the annotation fallback" {
    # DEVOPS-1029: the fetch succeeds (exit 0) but writes nothing. Before the fix
    # this was treated as "no signature" and the run was silently not retried.
    export STUB_JOBS="123"
    export STUB_LOG_EMPTY="1"
    export STUB_ANNOTATIONS="$LOST_COMMS"
    source "$SCRIPT"
    run retry_run_on_runner_loss "o/r" "999" "1" "2"
    [ "$status" -eq 0 ]
    [ -f "$RERUN_MARKER" ]
    [[ "$output" == *"returned an empty body"* ]]
    [[ "$output" == *"checking check-run annotations"* ]]
}

@test "AC1: an empty log body with no annotation does not retry" {
    export STUB_JOBS="123"
    export STUB_LOG_EMPTY="1"
    source "$SCRIPT"
    run retry_run_on_runner_loss "o/r" "999" "1" "2"
    [ "$status" -eq 0 ]
    [ ! -f "$RERUN_MARKER" ]
    [[ "$output" == *"returned an empty body"* ]]
}

@test "AC2: a non-empty log without the signature never consults annotations" {
    # The DEVOPS-990 fail-safe: a readable log is authoritative. An ambiguous
    # annotation must not be able to turn a genuine failure into a retry.
    export STUB_JOBS="123"
    export STUB_LOG="genuine failure output"
    export STUB_ANNOTATIONS="$LOST_COMMS"
    source "$SCRIPT"
    run retry_run_on_runner_loss "o/r" "999" "1" "2"
    [ "$status" -eq 0 ]
    [ ! -f "$RERUN_MARKER" ]
    [[ "$output" == *"not consulting annotations"* ]]
    [[ "$output" != *"checking check-run annotations"* ]]
}
