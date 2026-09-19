#!/usr/bin/env bash
# Test harness for the bash-lib helpers. Each case runs in a SUBSHELL with
# set -euo pipefail (mirroring writeShellApplication) so an unexpected abort is caught
# as a test failure, not a harness death.
# Run from anywhere: bash lib/bash-lib-test.sh
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bash-lib.sh"
[ -r "$LIB" ] || { echo "FATAL: $LIB not found" >&2; exit 1; }
pass=0 fail=0

check() { # check <name> <expected_rc> <bash-snippet>
  local name="$1" want="$2" snippet="$3" rc=0 out
  out="$(bash -c "set -euo pipefail; source $LIB; $snippet" 2>&1)" || rc=$?
  if [ "$rc" = "$want" ]; then
    pass=$((pass + 1)); echo "PASS  $name (rc=$rc)"
  else
    fail=$((fail + 1)); echo "FAIL  $name: want rc=$want got rc=$rc"; echo "$out" | sed 's/^/      /'
  fi
}

expect_in_out() { # expect_in_out <name> <pattern> <bash-snippet>
  local name="$1" pat="$2" snippet="$3" out
  out="$(bash -c "set -euo pipefail; source $LIB; $snippet" 2>&1)" || true
  if grep -q "$pat" <<<"$out"; then
    pass=$((pass + 1)); echo "PASS  $name"
  else
    fail=$((fail + 1)); echo "FAIL  $name: '$pat' not in output:"; echo "$out" | sed 's/^/      /'
  fi
}

tmpfile_count() { find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -l; }

# --- run -------------------------------------------------------------------------------
check "run: success is quiet on stdout, rc 0" 0 \
  'out=$(run "ok" echo DATA); [ -z "$out" ]'
check "run: forwards command exit code" 7 \
  'run "doomed" sh -c "exit 7"'
expect_in_out "run: failure replays buffered output to stderr" 'CMD-NOISE' \
  'run "noisy" sh -c "echo CMD-NOISE; exit 1" || true'
check "run: usage error is 254" 254 \
  'run "only-caption" || exit $?; exit 0'
check "run: no temp file left behind (success + failure)" 0 \
  'b=$('"$(printf '%s' 'find "${TMPDIR:-/tmp}" -maxdepth 1 -name "tmp.*" | wc -l')"')
   run "ok" true; run "bad" false || true
   a=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name "tmp.*" | wc -l); [ "$b" = "$a" ]'
check "run: no temp file even when the command is killed" 0 \
  'b=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name "tmp.*" | wc -l)
   run "killed" sh -c "kill -9 \$\$" || true
   a=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name "tmp.*" | wc -l); [ "$b" = "$a" ]'
check "run: stdin passes through for deliberate feeding" 0 \
  'echo PAYLOAD | run "feed" sh -c "grep -q PAYLOAD"'
check "run: common var names in wrapped function do not clobber internals" 0 \
  'build() { rc=17; caption=X; path=/nope; fd=99; return 0; }; run "guard" build'
check "run: buffer fd is NOT inherited by the child" 0 \
  'probe() { ! ls /proc/self/fd | grep -qE "^[0-9]{2,}$"; }
   run "fds" probe'
check "run: errexit-suspension documented behavior pinned (falls through to 127)" 127 \
  'build() { set -e; echo before; false; echo after; xxx; }
   run "build" build 2>/dev/null'

# --- best_effort -----------------------------------------------------------------------
check "best_effort: failing cmd does not abort under set -e" 0 \
  'best_effort "rm scratch" false; echo survived >&2'
expect_in_out "best_effort: WARN with exit code logged" 'WARN: rm scratch failed (exit 1)' \
  'best_effort "rm scratch" false'
check "best_effort: succeeding cmd stays silent, rc 0" 0 \
  'out=$(best_effort "noop" true 2>&1); [ -z "$out" ]'
check "best_effort: usage error is 254" 254 \
  'best_effort "only-caption" || exit $?; exit 0'
check "best_effort: composes with run" 0 \
  'best_effort "x" run "x" false'

# --- wait_for --------------------------------------------------------------------------
check "wait_for: succeeds when condition comes true" 0 \
  'f=$(mktemp -d)/flag; ( sleep 0.3; touch "$f" ) & wait_for "flag" 20 0.1 test -e "$f"'
check "wait_for: returns LAST attempt exit code on expiry (3)" 3 \
  'wait_for "never" 2 0.05 sh -c "exit 3"; echo unreachable'
check "wait_for: vars filled on SUCCESS (separate streams)" 0 \
  'wait_for "probe" 3 0.05 sh -c "echo OUT; echo ERR >&2; exit 0"
   [ "$wait_for_rc" = 0 ] && [ "$wait_for_out" = OUT ] && [ "$wait_for_err" = ERR ]'
check "wait_for: vars filled on FAILURE (separate streams + rc)" 0 \
  'if wait_for "probe" 2 0.05 sh -c "echo O; echo E >&2; exit 9"; then exit 1; fi
   [ "$wait_for_rc" = 9 ] && [ "$wait_for_out" = O ] && [ "$wait_for_err" = E ]'
check "wait_for: vars hold ONLY the last attempt (buffers truncated)" 0 \
  'if wait_for "p" 3 0.01 sh -c "echo X; exit 1"; then exit 1; fi
   [ "$wait_for_out" = X ]'
expect_in_out "wait_for: expiry logs ONE error line with budget + exit" \
  'never: not ready after 2 tries x 0.05s (last exit 3)' \
  'wait_for "never" 2 0.05 sh -c "exit 3" || true'
check "wait_for: attempts are quiet (no probe output leaks while polling)" 0 \
  'out=$(wait_for "p" 3 0.01 sh -c "echo NOISE; echo NOISE >&2; exit 1" 2>/dev/null || true)
   [ -z "$out" ]'
check "wait_for: probe stdin DETACHED — while-read loop sees every line" 0 \
  'n=0
   while read -r host; do
     wait_for "up $host" 1 0.01 sh -c "cat >/dev/null; true" || true
     n=$((n + 1))
   done < <(printf "%s\n" h1 h2 h3)
   [ "$n" = 3 ]'
check "wait_for: usage error is 254 (missing args)" 254 \
  'wait_for "x" 1 || exit $?; exit 0'
check "wait_for: usage error is 254 (tries=0)" 254 \
  'wait_for "x" 0 1 true || exit $?; exit 0'
check "wait_for: usage error is 254 (tries not numeric)" 254 \
  'wait_for "x" lots 1 true || exit $?; exit 0'
check "wait_for: usage error is 254 (delay=abc)" 254 \
  'wait_for "x" 2 abc true || exit $?; exit 0'
check "wait_for: usage error is 254 (delay=-1)" 254 \
  'wait_for "x" 2 -1 true || exit $?; exit 0'
check "wait_for: delay=0 and float delay are valid" 0 \
  'wait_for "x" 2 0 true && wait_for "y" 2 0.1 true'
check "wait_for: vars RESET on usage error (no stale state)" 0 \
  'wait_for "ok" 1 0 sh -c "echo OLD; exit 0"
   wait_for "bad" 2 abc true || true
   [ "$wait_for_rc" = 254 ] && [ -z "$wait_for_out" ] && [ -z "$wait_for_err" ]'
check "wait_for: common var names in probe do not clobber internals" 3 \
  'probe() { rc=0; i=0; tries=999; delay=999; caption=X; wait_for_rc=0; return 3; }
   wait_for "guard" 2 0 probe 2>/dev/null; echo unreachable'
check "wait_for: buffer fds NOT inherited by the probe" 0 \
  'probe() { ! ls /proc/self/fd | grep -qE "^[0-9]{2,}$"; }
   wait_for "fds" 1 0 probe'
check "wait_for: no temp file left behind" 0 \
  'b=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name "tmp.*" | wc -l)
   wait_for "ok" 1 0.01 true; wait_for "no" 2 0.01 false || true
   a=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name "tmp.*" | wc -l); [ "$b" = "$a" ]'

# --- retry -----------------------------------------------------------------------------
check "retry: first success returns 0" 0 \
  'retry "job" 3 0.05 true'
check "retry: eventual success returns 0" 0 \
  'f=$(mktemp); retry "flaky" 5 0.05 sh -c "[ -s $f ] || { echo x > $f; exit 1; }"'
check "retry: exhausted forwards LAST exit code (7)" 7 \
  'retry "doomed" 2 0.05 sh -c "exit 7"'
expect_in_out "retry: failed attempt output is shown" 'attempt-noise' \
  'retry "noisy" 1 0.05 sh -c "echo attempt-noise; exit 1" || true'
check "retry: stdin DETACHED — while-read loop sees every line" 0 \
  'n=0
   while read -r host; do
     retry "job $host" 1 0.01 sh -c "cat >/dev/null; true" || true
     n=$((n + 1))
   done < <(printf "%s\n" h1 h2 h3)
   [ "$n" = 3 ]'
check "retry: usage error is 254 (tries=0)" 254 \
  'retry "x" 0 1 true || exit $?; exit 0'
check "retry: usage error is 254 (delay=abc)" 254 \
  'retry "x" 2 abc true || exit $?; exit 0'
check "retry: common var names in wrapped function do not clobber internals" 0 \
  'job() { rc=9; i=99; tries=0; return 0; }
   retry "guard" 2 0 job'

# --- add_cleanup -----------------------------------------------------------------------
check "add_cleanup: preserves success exit code" 0 \
  'add_cleanup "true"; exit 0'
check "add_cleanup: preserves failure exit code (5)" 5 \
  'add_cleanup "true"; exit 5'
check "add_cleanup: failing cleanup does not mask exit code" 0 \
  'add_cleanup "false"; exit 0'
expect_in_out "add_cleanup: failing cleanup WARN-logged, rest run" 'WARN: cleanup failed' \
  'add_cleanup "echo one >&2"; add_cleanup "false"; true'
check "add_cleanup: cleans a real tempdir" 0 \
  'w=$(mktemp -d); add_cleanup "rm -rf $(printf %q "$w") && echo GONE >&2"; test -d "$w"'
expect_in_out "add_cleanup: fires on fatal too" 'GONE' \
  'w=$(mktemp -d); add_cleanup "rm -rf $(printf %q "$w") && echo GONE >&2"; fatal boom'
check "add_cleanup: fatal exit code survives cleanup" 1 \
  'add_cleanup "true"; fatal boom'

# --- add_cleanup LIFO order (multiline output, so match via tr) --------------------------
lifo="$(bash -c "set -euo pipefail; source $LIB; add_cleanup 'echo first >&2'; add_cleanup 'echo second >&2'" 2>&1 | tr '\n' ' ')"
case "$lifo" in
  *second*first*) pass=$((pass + 1)); echo "PASS  add_cleanup LIFO order (verified)" ;;
  *) fail=$((fail + 1)); echo "FAIL  add_cleanup LIFO order: $lifo" ;;
esac

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
