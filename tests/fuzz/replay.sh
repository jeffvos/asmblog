#!/usr/bin/env bash
# replay.sh — every seed input (and every crash AFL ever saved under
# build/afl-out/) through the harnesses; a signal or an aborted invariant
# fails the run and names the input. Cheap enough for `make test`.
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
SITE="build/fuzz-replay-site"     # separate from afl.sh's, which may be in use
./tests/fuzz/site.sh "$SITE"
fail=0; n=0
run() {   # run <mode> <input>
    local out
    if [ "$1" = http ]; then
        out=$(./build/fuzz_http "$SITE" "$2" 2>&1); rc=$?
    else
        out=$(./build/fuzz_md "$2" 2>&1); rc=$?
    fi
    n=$((n+1))
    if [ "$rc" != 0 ]; then
        echo "FAIL - $1 harness on $2 (exit $rc)"; echo "$out" | tail -3; fail=1
    fi
}
for f in tests/fuzz/corpus/http/* build/afl-out/http/*/crashes/id:* ; do [ -e "$f" ] && run http "$f"; done
for f in tests/fuzz/corpus/md/*   build/afl-out/md/*/crashes/id:*   ; do [ -e "$f" ] && run md "$f"; done
if [ "$fail" = 0 ]; then echo "replay: $n inputs, no crashes, invariants held"; else echo "replay: FAILURES"; exit 1; fi
