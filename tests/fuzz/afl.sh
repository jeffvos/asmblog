#!/usr/bin/env bash
# afl.sh http|md [extra afl-fuzz args] — coverage-guided fuzzing of a
# parser with AFL++.
#
# The parsers are assembly, so coverage comes from AFL++'s binary-only
# FRIDA mode (afl-fuzz -O; QEMU mode works the same way with -Q). Needs
# afl-fuzz on PATH and afl-frida-trace.so where afl-fuzz looks for it
# (AFL_PATH, or the install prefix). One exec per input: about 400-650
# executions per second per core here, and the edge count climbs from
# the first seconds (a few hundred edges, a few hundred new corpus
# entries in the first minute). FRIDA's persistent mode was tried and
# produced no coverage with these harnesses, so it is not used; run
# several instances (-M/-S) for more throughput.
#
#   make afl MODE=http                    # runs until interrupted
#   FUZZ_TIME=600 tests/fuzz/afl.sh md    # ten minutes, then exits
#
# Findings land in build/afl-out/<mode>/default/crashes/; replay.sh
# re-runs them (with the corpus) on every `make fuzz` and `make test`,
# so a crash found once stays a regression test. Minimise a grown
# corpus with afl-cmin before promoting it to tests/fuzz/corpus/.
set -euo pipefail
cd "$(dirname "$0")/../.."
MODE="${1:-http}"; shift || true
command -v afl-fuzz >/dev/null || { echo "afl.sh: afl-fuzz not on PATH (build AFL++; FRIDA mode: make -C frida_mode)"; exit 1; }
case "$MODE" in
  http) ./tests/fuzz/site.sh build/fuzz-site; TARGET=(./build/fuzz_http build/fuzz-site @@); MAXLEN=65536 ;;
  md)   TARGET=(./build/fuzz_md @@); MAXLEN=32768 ;;
  *) echo "afl.sh: mode is http or md"; exit 1 ;;
esac
export AFL_SKIP_CPUFREQ=1 AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 AFL_NO_AFFINITY=1
OUT="build/afl-out/$MODE"
mkdir -p "$OUT"
RESUME=()
[ -e "$OUT/default/fuzzer_stats" ] && RESUME=(-i -) || RESUME=(-i "tests/fuzz/corpus/$MODE")
TIMEOPT=()
[ -n "${FUZZ_TIME:-}" ] && TIMEOPT=(-V "$FUZZ_TIME")
exec afl-fuzz -O "${RESUME[@]}" -o "$OUT" -x "tests/fuzz/$MODE.dict" -G "$MAXLEN" -t 2000 "${TIMEOPT[@]}" "$@" -- "${TARGET[@]}"
