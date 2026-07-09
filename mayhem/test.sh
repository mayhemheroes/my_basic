#!/usr/bin/env bash
# my_basic/mayhem/test.sh — GOLDEN / known-answer oracle for the MY-BASIC interpreter.
#
# my_basic ships NO unit-test suite (its makefile has no test target). It DOES ship a set of
# example BASIC programs under sample/. We turn the DETERMINISTIC ones (no input/, no rand/time)
# into a known-answer functional oracle:
#
#   * mayhem/build.sh built /mayhem/my_basic-tests with the project's NORMAL flags (NO sanitizer),
#     so the oracle exercises the real shipped interpreter behavior and never false-fails on the
#     benign UB the fuzz build deliberately relaxes. This script only RUNS that binary — it never
#     compiles (PATCH grading: patch -> build.sh -> test.sh).
#   * For each sample program it runs the interpreter and DIFFs stdout+stderr against a committed
#     golden file (mayhem/testdata/golden/<name>.out). The goldens were captured once from the
#     normal-flags binary and verified byte-stable across repeated runs.
#
# This is a PATCH-grade, anti-reward-hack oracle by construction: it asserts the EXACT computed
# OUTPUT of each program (e.g. "Hello world!", the first 15 primes, a Fibonacci sequence,
# class-method dispatch), not merely "exited 0". A no-op / exit(0) "patch", or any change that
# breaks the parser/runtime so a program stops producing its correct output, FAILS the diff.
set -uo pipefail

# clang/gcc reject SOURCE_DATE_EPOCH='' (empty); must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"

# SRC is /mayhem in the commit image; default to this checkout's repo root so the suite also runs
# straight from a developer checkout (mayhem/ is one level below the repo root).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${SRC:=$(cd "$HERE/.." && pwd)}"
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

# The normal-flags oracle binary that build.sh produced.
BIN="$SRC/my_basic-tests"
[ -x "$BIN" ] || { echo "missing $BIN — run mayhem/build.sh first" >&2; emit_ctrf "my_basic-golden" 0 1; exit 2; }

GOLDEN="$SRC/mayhem/testdata/golden"
[ -d "$GOLDEN" ] || { echo "missing golden dir $GOLDEN — wrong tree?" >&2; emit_ctrf "my_basic-golden" 0 1; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

passed=0; failed=0

# run_case <name> <sample-file>
# Runs the interpreter on sample/<file>, diffs combined stdout+stderr against
# mayhem/testdata/golden/<name>.out. MUST exit 0 AND match the golden byte-for-byte.
run_case() {
  local name="$1" prog="$2"
  local gold="$GOLDEN/$name.out" got="$WORK/$name.out" rc
  if [ ! -f "$gold" ]; then
    echo "FAIL $name: missing golden $gold" >&2; failed=$((failed+1)); return
  fi
  if [ ! -f "$SRC/$prog" ]; then
    echo "FAIL $name: missing sample $SRC/$prog" >&2; failed=$((failed+1)); return
  fi
  "$BIN" "$SRC/$prog" > "$got" 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL $name: my_basic $prog exited $rc (expected 0)" >&2
    sed 's/^/    /' "$got" >&2
    failed=$((failed+1)); return
  fi
  if diff -u "$gold" "$got" > "$WORK/$name.diff" 2>&1; then
    echo "PASS $name"; passed=$((passed+1))
  else
    echo "FAIL $name: output differs from golden" >&2
    head -20 "$WORK/$name.diff" | sed 's/^/    /' >&2
    failed=$((failed+1))
  fi
}

# Deterministic sample programs (no input/, no rand/time). Each exercises a different language
# feature path: strings, primes loop, dim/array+fibonacci, def/call functions, class dispatch.
run_case sample01 sample/sample01.bas   # string concat -> "Hello world!"
run_case sample02 sample/sample02.bas   # prime sieve up to 50
run_case sample04 sample/sample04.bas   # dim arrays + fibonacci
run_case sample05 sample/sample05.bas   # def/return/call user functions
run_case sample06 sample/sample06.bas   # class + method dispatch

emit_ctrf "my_basic-golden" "$passed" "$failed"
