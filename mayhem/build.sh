#!/usr/bin/env bash
# my_basic/mayhem/build.sh — build the MY-BASIC interpreter shell as the fuzz target.
#
# my_basic is a single-file BASIC interpreter: core/my_basic.c is the whole language core
# (lexer, parser, runtime) and shell/main.c is a thin CLI driver that loads a .bas source file
# (mb_load_file → mb_run) and interprets it. The Mayhem target is FILE-INPUT (CLI): the fuzz
# bytes are handed to /mayhem/my_basic as a BASIC source file, exercising the entire
# parse + run pipeline. There is NO libFuzzer harness — the interpreter binary IS the natural
# fuzz surface, exactly like the lacc/file-input template (so no *-standalone reproducer either:
# the file-input target already crashes naturally on a single input file).
#
# build.sh produces TWO binaries from the same single-file source:
#   (1) /mayhem/my_basic        — SANITIZED + AFL-instrumented fuzz target (ASan+UBSan halting,
#                                 by default). AFL compile-time instrumentation (afl-clang-fast)
#                                 gives Mayhem instrumented edge coverage (`afl: true` in the
#                                 Mayhemfile); a plain black-box CLI binary can fuzz yet record
#                                 0 edges via the binary-only tracer (SPEC.md §gate 11).
#   (2) /mayhem/my_basic-tests  — NORMAL-flags oracle binary for mayhem/test.sh (no sanitizers,
#                                 so the golden suite exercises real shipped behavior and never
#                                 false-fails on the benign UB the fuzz build deliberately relaxes)
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the base ENV, overridable. SANITIZER_FLAGS uses `=` (not `:=`) so an explicit
# empty value (--build-arg SANITIZER_FLAGS=) is honored → no-sanitizer build (the interpreter's
# natural crash). The build links only -lm (libc math), which is present without the sanitizer
# runtime, so the empty-sanitizer build links cleanly.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
# AFL instrumentation for the fuzz binary only (the test oracle stays plain $CC). afl-clang-fast
# wraps clang, passing -fsanitize/-g through; fall back to plain $CC if AFL is absent. NOT named
# (or exported as) AFL_CC — afl-cc reads the AFL_CC env var as the underlying compiler to exec,
# so AFL_CC=afl-clang-fast would make it re-exec itself until it aborts.
FUZZ_CC=afl-clang-fast
command -v "$FUZZ_CC" >/dev/null 2>&1 || FUZZ_CC="$CC"
export SANITIZER_FLAGS DEBUG_FLAGS CC MAYHEM_JOBS

cd "$SRC"

# my_basic's upstream makefile compiles with these warning suppressions (-Wno-multichar etc.);
# keep them so the build stays quiet. -Os matches upstream's optimization choice.
CORE_WARN="-Wno-multichar -Wno-overflow -Wno-unused-result"
SHELL_WARN="-Wno-unused-result"
INCLUDE="-Icore"

# ---------------------------------------------------------------------------
# Benign-UB relaxation (PORTING.md "benign UB that floods under halting UBSan").
# my_basic trips TWO ubiquitous, benign UBSan checks on essentially EVERY input — they fire
# during normal interpreter setup/list operations, BEFORE any real defect can be reached, so
# halting UBSan would abort the fuzzer on the default seed and every valid program:
#   * alignment        — _ht_set_or_insert (my_basic.c:~3097) stores an _ls_node_t* through a
#                        bucket slot that is not 8-byte aligned. x86 tolerates the misaligned
#                        store; it happens for every symbol interned, i.e. every program.
#   * pointer-overflow — _ls_pushback (my_basic.c:~2468) does `list->data = (char*)list->data + 1`
#                        to use the list head's data field as an element COUNT, starting from NULL
#                        (NULL + 1). This is the project's list-length idiom and runs on every push.
# We relax ONLY these two checks, and ONLY when UBSan is active (the no-sanitizer off-switch stays
# a clean build). ASan and the REST of UBSan remain ON and HALTING, so real memory/UB defects in
# the parser/runtime still crash the fuzz target. Smoke-tested: every deterministic sample runs to
# exit 0 with no sanitizer output after the relaxation.
UBSAN_RELAX=""
if printf '%s' "$SANITIZER_FLAGS" | grep -q undefined; then
  UBSAN_RELAX="-fno-sanitize=alignment,pointer-overflow"
fi

# ---------------------------------------------------------------------------
# (1) FUZZ build — the interpreter compiled WITH $SANITIZER_FLAGS so the fuzzed code (the whole
#     language core + shell) is instrumented. File-input Mayhem target lands at /mayhem/my_basic.
# ---------------------------------------------------------------------------
$FUZZ_CC $SANITIZER_FLAGS $DEBUG_FLAGS $UBSAN_RELAX $INCLUDE -Os -c core/my_basic.c $CORE_WARN -o /tmp/my_basic.core.o
$FUZZ_CC $SANITIZER_FLAGS $DEBUG_FLAGS $UBSAN_RELAX $INCLUDE -Os -c shell/main.c    $SHELL_WARN -o /tmp/my_basic.main.o
# Bake detect_leaks=0 into the binary: LSan fails under Mayhem's ptrace-based coverage tracer
# (exits 1 → 0 edges). The weak __asan_default_options fills in gaps not covered by Mayhem's
# runtime ASAN_OPTIONS, so detect_leaks=0 takes effect before LSan initialises.
$FUZZ_CC $SANITIZER_FLAGS $DEBUG_FLAGS         -Os -c mayhem/asan_options.c            -o /tmp/my_basic.asan.o
$FUZZ_CC $SANITIZER_FLAGS $DEBUG_FLAGS $UBSAN_RELAX -o /mayhem/my_basic /tmp/my_basic.core.o /tmp/my_basic.main.o /tmp/my_basic.asan.o -lm

# ---------------------------------------------------------------------------
# (2) TEST-ORACLE build — the SAME source with the project's NORMAL flags (no sanitizer), for
#     mayhem/test.sh's golden-output suite. A clean, independent build so the oracle reflects real
#     shipped behavior; test.sh only RUNS this binary (it never compiles).
# ---------------------------------------------------------------------------
$CC $INCLUDE -Os -c core/my_basic.c $CORE_WARN -o /tmp/my_basic.core.test.o
$CC $INCLUDE -Os -c shell/main.c    $SHELL_WARN -o /tmp/my_basic.main.test.o
$CC -o /mayhem/my_basic-tests /tmp/my_basic.core.test.o /tmp/my_basic.main.test.o -lm

echo "build.sh: built /mayhem/my_basic (sanitized fuzz target) and /mayhem/my_basic-tests (test oracle)"
ls -l /mayhem/my_basic /mayhem/my_basic-tests
