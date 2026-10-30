#!/usr/bin/env bash
#
# mayhem/test.sh — RUN mGBA's OWN functional tests (already built by mayhem/build.sh into build-tests/):
# the cmocka unit-test binaries and the mgba-cinema screenshot-baseline suite.
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Every runner's own summary line is parsed; a binary that prints no summary (crash, neutered to
# exit(0), missing) counts as failed, so a no-op "fix" cannot pass.
T=build-tests/test
passed=0; failed=0; bins=0; cases=0

for bin in "$T"/test-*; do
  [ -f "$bin" ] && [ -x "$bin" ] || continue
  bins=$((bins + 1))
  out=$("$bin" 2>&1); rc=$?
  ran=$(printf '%s\n' "$out" | sed -n 's/^\[==========\] .*: \([0-9][0-9]*\) test(s) run\.$/\1/p' | tail -1)
  ok=$(printf '%s\n' "$out" | sed -n 's/^\[  PASSED  \] \([0-9][0-9]*\) test(s)\.$/\1/p' | tail -1)
  bad=$(printf '%s\n' "$out" | sed -n 's/^\[  FAILED  \] \([0-9][0-9]*\) test(s), listed below:$/\1/p' | tail -1)
  if [ -z "$ran" ] || [ "${ran:-0}" -eq 0 ] || [ "$rc" -ne 0 ] || [ -n "$bad" ]; then
    echo "FAIL: $bin (rc=$rc ran=${ran:-none} passed=${ok:-0} failed=${bad:-?})" >&2
    printf '%s\n' "$out" | tail -20 >&2
    failed=$((failed + ${bad:-1}))
    passed=$((passed + ${ok:-0}))
    cases=$((cases + ${ran:-0}))
  else
    passed=$((passed + ok))
    cases=$((cases + ran))
  fi
done

# Floors: mGBA ships 24 cmocka binaries with 300+ cases; fewer means the build/test set was gutted.
[ "$bins" -ge 20 ] || { echo "FAIL: only $bins test-* binaries found in $T (expected >= 20)" >&2; failed=$((failed + 1)); }
[ "$cases" -ge 250 ] || { echo "FAIL: only $cases cmocka cases ran (expected >= 250)" >&2; failed=$((failed + 1)); }

# mgba-cinema: run every ROM-based screenshot test and compare against the checked-in baselines.
CIN="$T/mgba-cinema"
if [ ! -x "$CIN" ]; then
  echo "FAIL: $CIN missing (build.sh should have built it)" >&2
  failed=$((failed + 1))
else
  expected=$("$CIN" -n 2>/dev/null | grep -c .)
  cout=$("$CIN" -j"$MAYHEM_JOBS" -v 2>&1); crc=$?
  cpass=$(printf '%s\n' "$cout" | grep -c ': pass$')
  cxfail=$(printf '%s\n' "$cout" | grep -c ': xfail$')
  cfail=$(printf '%s\n' "$cout" | grep -c ': fail$')
  echo "mgba-cinema: expected=$expected pass=$cpass xfail=$cxfail fail=$cfail rc=$crc"
  if [ "$expected" -lt 200 ] || [ "$cfail" -ne 0 ] || [ $((cpass + cxfail)) -ne "$expected" ] || [ "$cpass" -lt 150 ]; then
    echo "FAIL: mgba-cinema did not match its baselines" >&2
    printf '%s\n' "$cout" | grep -v ': pass$' | grep -v ': xfail$' | tail -20 >&2
    failed=$((failed + cfail + 1))
    passed=$((passed + cpass))
  else
    passed=$((passed + cpass + cxfail))
  fi
fi

emit_ctrf "cmocka+mgba-cinema" "$passed" "$failed" 0
