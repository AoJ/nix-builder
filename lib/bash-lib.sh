# Shared bash helpers. Prepended (by lib/bash-tool.nix) or sourced into a script that
# runs under `set -euo pipefail`. No shebang, no `set` here — it inherits both.
#
# - info/error/fatal : timestamped, levelled logging to stderr (never stdout).
# - required         : fail fast if a named variable is empty/unset.
# - run              : run ONE command, output buffered (fd-backed); replayed to stderr
#                      only if the command fails.
# - best_effort      : run a command whose failure is tolerated — logged WARN, never
#                      aborts. The explicit replacement for `|| true`.
# - wait_for         : bounded poll of a condition; quiet attempts. Returns the LAST
#                      attempt's exit code and exposes its stdout/stderr SEPARATELY
#                      in $wait_for_out / $wait_for_err (success or failure alike).
# - retry            : bounded LOUD re-run of a real command (run-buffered attempts).
# - add_cleanup      : register cleanup commands into the script's SINGLE EXIT trap.
#
# !! ERREXIT SUSPENSION — READ THIS !!
# Bash suspends `set -e` for the ENTIRE call tree of anything executed in a tested
# context: `if cmd`, `cmd || x`, `cmd && x` — and therefore inside EVERY wrapper here
# (they must test the command to capture its exit). A multi-step FUNCTION passed to
# run/wait_for/retry/best_effort CANNOT rely on set -e internally:
#     build() { set -e; step1; step2; }     # direct call: step1 failure stops it
#     run "build" build                     # via run: step1 failure FALLS THROUGH to step2
# This is bash semantics; no wrapper can restore it. Wrap single COMMANDS. A function
# handed to a wrapper must handle each step itself (`step1 || return`).
#
# RESERVED EXIT CODES of the wrappers (distinguish helper-infra failure from the wrapped
# command's own exit): 254 = usage error, 253 = mktemp failed, 252 = fd setup failed.
# A wrapped command could legitimately exit with these too — treat them as suspect.
#
# Buffering uses the unlink-early fd idiom: mktemp, open an fd, rm the path at once, so
# the inode lives only as long as the fd and the leak window is minimal (a kill between
# mktemp and rm, or a failed rm, can still leak ONE empty temp file — nothing grows).
# Reads reopen the inode at offset 0 via /proc/self/fd/N (Linux-only; fine here). The
# buffer fd is closed for the wrapped command itself ({fd}>&-), so children never
# inherit it — a daemonizing child can't pin the inode alive.
#
# Lib functions that EXECUTE CALLER CODE prefix their locals (__bashlib_*): bash
# locals are dynamically scoped, so an unprefixed `local rc` would be silently writable
# by the very function the caller passed in.

bashlib_cdate() {
  date +"%Y-%m-%d %H:%M:%S"
}

# shellcheck disable=SC2329  # helper is prepended into every tool; not every tool calls it
info() {
  printf '[%s] INFO  %s\n' "$(bashlib_cdate)" "$*" >&2
}

# Returns 1. NB under `set -e` a bare `error "..." ; return` aborts the whole script at
# the `error` — that pattern only works where errexit is suspended (inside an `if`/`||`
# call chain). In plain code write: `error "..." || return`.
# shellcheck disable=SC2329  # helper is prepended into every tool; not every tool calls it
error() {
  printf '[%s] ERROR %s\n' "$(bashlib_cdate)" "$*" >&2
  return 1
}

# shellcheck disable=SC2329  # helper is prepended into every tool; not every tool calls it
fatal() {
  printf '[%s] FATAL %s\n' "$(bashlib_cdate)" "$*" >&2
  exit 1
}

# shellcheck disable=SC2329  # helper is prepended into every tool; not every tool calls it
required() {
  local var

  for var in "$@"; do
    if [ -z "${!var:-}" ]; then
      fatal "internal error: \$$var is not set"
    fi
  done
}

# run <caption> <cmd...> — run ONE command with stdout+stderr buffered; on failure the
# whole buffer is replayed to STDERR (stdout stays reserved for raw data). Returns the
# command's exit. stdin passes through (a single-shot wrapper may be fed deliberately:
# `run "import" nix-store --import < closure`); in a `while read` loop detach it
# yourself (`</dev/null`, `ssh -n`) or the command eats the loop's input.
# Mind the errexit-suspension warning in the header: wrap COMMANDS, not set-e-reliant
# multi-step functions.
# shellcheck disable=SC2329  # helper is prepended into every tool; not every tool calls it
run() {
  if [ "$#" -lt 2 ]; then
    printf >&2 'Usage: run CAPTION COMMAND [ARG...]\n'
    return 254
  fi

  local __bashlib_run_caption="$1"
  shift

  local __bashlib_run_rc=0
  local __bashlib_run_path
  local __bashlib_run_fd

  __bashlib_run_path="$(mktemp)" || return 253
  exec {__bashlib_run_fd}<>"$__bashlib_run_path" ||
    { rm -f -- "$__bashlib_run_path"; return 252; }
  rm -f -- "$__bashlib_run_path"

  info "$__bashlib_run_caption ..."

  if { "$@"; }                        \
    >&"$__bashlib_run_fd"          \
    2>&1                              \
    {__bashlib_run_fd}>&-
  then
    __bashlib_run_rc=0
  else
    __bashlib_run_rc=$?
  fi

  if [ "$__bashlib_run_rc" -ne 0 ]; then
    printf '[%s] ERROR %s failed (exit %s); output:\n' \
      "$(bashlib_cdate)" "$__bashlib_run_caption" "$__bashlib_run_rc" >&2
    cat "/proc/self/fd/$__bashlib_run_fd" >&2 ||
      printf >&2 'bashlib: unable to replay buffered output\n'
  fi

  # : — closing a just-used fd cannot reasonably fail; never let it mask the real exit.
  exec {__bashlib_run_fd}>&- || :

  return "$__bashlib_run_rc"
}

# A TRANSPORT failure of an ssh call: ssh's own 255 (couldn't connect / connection
# dropped), or `timeout` killing a hung ssh (124). In both we never reached the host,
# so a poller must RETRY — it learnt nothing. Any OTHER exit is a real answer FROM the
# host, including a remote command's own non-zero (e.g. `systemctl is-active` returns 3
# for an inactive/failed unit). Distinguishing the two is what stops a poller from
# reading a momentary blip as "the unit finished/failed".
# shellcheck disable=SC2329  # helper is prepended into every tool; not every tool calls it
transient_ssh() { [ "$1" = 255 ] || [ "$1" = 124 ]; }

# best_effort <caption> <cmd...> — run a command whose failure is TOLERATED (cleanup,
# an optional nicety), always returning 0. The failure still lands in the log as a WARN
# with the exit code, so "it silently didn't happen" can't hide — which is exactly what
# a bare `|| true` allows. Every call is an explicit, grep-able decision; the caption
# should say what is being tolerated. Never wrap a command the script depends on.
# Composes with run for output buffering: best_effort "x" run "x" cmd ...
# shellcheck disable=SC2329  # helper is prepended into every tool; not every tool calls it
best_effort() {
  if [ "$#" -lt 2 ]; then
    printf >&2 'Usage: best_effort CAPTION COMMAND [ARG...]\n'
    return 254
  fi

  local __bashlib_be_caption="$1"
  shift

  local __bashlib_be_rc=0
  "$@" || __bashlib_be_rc=$?

  if [ "$__bashlib_be_rc" -ne 0 ]; then
    info "WARN: $__bashlib_be_caption failed (exit $__bashlib_be_rc); continuing"
  fi

  return 0
}

# wait_for <caption> <tries> <delay> <cmd...> — poll a CONDITION: at most <tries>
# attempts, <delay>s apart (no sleep after the last). A failing probe is the EXPECTED
# state, so attempts are silent; the LAST attempt's result — success or failure — is
# handed to the caller instead of printed:
#   return value    = last attempt's exit code (0 iff the condition came true)
#   $wait_for_rc    = the same code (survives an `if wait_for ...` context)
#   $wait_for_out   = last attempt's stdout   (separate streams; trailing \n stripped)
#   $wait_for_err   = last attempt's stderr
# The variables are RESET on every call (an infra failure leaves rc = the reserved code
# and empty streams, never a previous call's state). On expiry ONE ERROR line is logged
# (budget + exit); the evidence is in the variables:
#   wait_for "factory sshd" 120 5 fac_ssh true || fatal "factory dead: $wait_for_err"
# stdin of the probe is DETACHED (</dev/null): attempts repeat, and a probe that reads
# stdin (ssh!) would eat the caller's input — e.g. the rest of a `while read` loop.
# Buffers are fd-backed and per-attempt truncated (reopening /proc/self/fd/N with `>`
# truncates at offset 0 while the inode stays owned by our fds), so the variables never
# contain an older attempt's output; the fds are closed for the probe itself. Probes are
# expected to be small; don't wait_for something that prints megabytes (the streams land
# in shell variables). Mind the errexit-suspension warning in the header.
wait_for_rc=0
wait_for_out=""
wait_for_err=""
# shellcheck disable=SC2329  # helper is prepended into every tool; not every tool calls it
wait_for() {
  wait_for_rc=254
  wait_for_out=""
  wait_for_err=""

  if [ "$#" -lt 4 ] ||
    ! [[ "$2" =~ ^[1-9][0-9]*$ ]] ||
    ! [[ "$3" =~ ^[0-9]+([.][0-9]+)?$ ]]
  then
    printf >&2 'Usage: wait_for CAPTION TRIES(>=1) DELAY(>=0 seconds) COMMAND [ARG...]\n'
    return 254
  fi

  local __bashlib_wf_caption="$1"
  local __bashlib_wf_tries="$2"
  local __bashlib_wf_delay="$3"
  shift 3

  # Two unlink-early buffers: one per stream.
  local __bashlib_wf_path
  local __bashlib_wf_ofd
  local __bashlib_wf_efd

  __bashlib_wf_path="$(mktemp)" ||
    { wait_for_rc=253; return 253; }
  exec {__bashlib_wf_ofd}<>"$__bashlib_wf_path" ||
    { rm -f -- "$__bashlib_wf_path"; wait_for_rc=252; return 252; }
  rm -f -- "$__bashlib_wf_path"

  __bashlib_wf_path="$(mktemp)" ||
    { exec {__bashlib_wf_ofd}>&- || :; wait_for_rc=253; return 253; }
  exec {__bashlib_wf_efd}<>"$__bashlib_wf_path" ||
    {
      rm -f -- "$__bashlib_wf_path"
      exec {__bashlib_wf_ofd}>&- || :
      wait_for_rc=252
      return 252
    }
  rm -f -- "$__bashlib_wf_path"

  local __bashlib_wf_i=0

  while [ "$__bashlib_wf_i" -lt "$__bashlib_wf_tries" ]; do
    __bashlib_wf_i=$((__bashlib_wf_i + 1))

    if { "$@" </dev/null; }                       \
      >"/proc/self/fd/$__bashlib_wf_ofd"       \
      2>"/proc/self/fd/$__bashlib_wf_efd"      \
      {__bashlib_wf_ofd}>&-                    \
      {__bashlib_wf_efd}>&-
    then
      wait_for_rc=0
      break
    else
      wait_for_rc=$?
    fi

    if [ "$__bashlib_wf_i" -lt "$__bashlib_wf_tries" ]; then
      sleep "$__bashlib_wf_delay"
    fi
  done

  # shellcheck disable=SC2034  # public output: callers read $wait_for_out; SC2034 can't see external reads
  wait_for_out="$(cat "/proc/self/fd/$__bashlib_wf_ofd")" ||
    wait_for_out='(bashlib: unable to replay probe stdout)'
  # shellcheck disable=SC2034  # public output: callers read $wait_for_err; SC2034 can't see external reads
  wait_for_err="$(cat "/proc/self/fd/$__bashlib_wf_efd")" ||
    wait_for_err='(bashlib: unable to replay probe stderr)'

  # : — closing just-used fds cannot reasonably fail; never let it mask the probe's exit.
  exec {__bashlib_wf_ofd}>&- {__bashlib_wf_efd}>&- || :

  if [ "$wait_for_rc" -ne 0 ]; then
    printf '[%s] ERROR %s: not ready after %s tries x %ss (last exit %s)\n'   \
      "$(bashlib_cdate)"                                                   \
      "$__bashlib_wf_caption"                                              \
      "$__bashlib_wf_tries"                                                \
      "$__bashlib_wf_delay"                                                \
      "$wait_for_rc"                                                          >&2
  fi

  return "$wait_for_rc"
}

# retry <caption> <tries> <delay> <cmd...> — re-run a REAL command (side effects; output
# that matters) up to <tries> times. Unlike wait_for's quiet probing, every attempt is
# run-buffered: silent when it succeeds, full output to stderr when it fails — so flaky
# attempts leave evidence. Returns 0 on the first success, else the LAST attempt's exit
# code. stdin is DETACHED (attempts repeat; see wait_for). For ssh'd commands consider a
# transient_ssh-aware poll instead: retry can't tell a transport blip from a real remote
# failure, so only retry what is safe to re-run. Mind the errexit-suspension warning.
# shellcheck disable=SC2329  # helper is prepended into every tool; not every tool calls it
retry() {
  if [ "$#" -lt 4 ] ||
    ! [[ "$2" =~ ^[1-9][0-9]*$ ]] ||
    ! [[ "$3" =~ ^[0-9]+([.][0-9]+)?$ ]]
  then
    printf >&2 'Usage: retry CAPTION TRIES(>=1) DELAY(>=0 seconds) COMMAND [ARG...]\n'
    return 254
  fi

  local __bashlib_rt_caption="$1"
  local __bashlib_rt_tries="$2"
  local __bashlib_rt_delay="$3"
  shift 3

  local __bashlib_rt_i=0
  local __bashlib_rt_rc=0

  while [ "$__bashlib_rt_i" -lt "$__bashlib_rt_tries" ]; do
    __bashlib_rt_i=$((__bashlib_rt_i + 1))

    __bashlib_rt_rc=0
    run "$__bashlib_rt_caption (attempt $__bashlib_rt_i/$__bashlib_rt_tries)" \
      "$@" </dev/null || __bashlib_rt_rc=$?

    if [ "$__bashlib_rt_rc" -eq 0 ]; then
      return 0
    fi

    if [ "$__bashlib_rt_i" -lt "$__bashlib_rt_tries" ]; then
      sleep "$__bashlib_rt_delay"
    fi
  done

  printf '[%s] ERROR %s: failed after %s attempts (last exit %s)\n'   \
    "$(bashlib_cdate)"                                             \
    "$__bashlib_rt_caption"                                        \
    "$__bashlib_rt_tries"                                          \
    "$__bashlib_rt_rc"                                             >&2

  return "$__bashlib_rt_rc"
}

# add_cleanup <command string> — register cleanup into the script's ONE EXIT trap.
# `trap` REPLACES the previous handler rather than stacking, which is how a second
# `trap ... EXIT` silently disables the first; this keeps every cleanup in one handler.
# Commands run LIFO (teardown mirrors setup), each best-effort (a failing cleanup is
# WARN-logged, the rest still run), and the script's real exit code is preserved.
# The argument is eval'd at exit: pass a READY-MADE string, expanding values NOW —
# quote anything dynamic in with printf %q:
#   work="$(mktemp -d)"
#   add_cleanup "rm -rf $(printf '%q' "$work")"
#   add_cleanup "kill $pid 2>/dev/null"
_bashlib_cleanup=()

# shellcheck disable=SC2329  # invoked via the EXIT trap string, which shellcheck cannot see
_bashlib_run_cleanup() {
  local __bashlib_cl_rc=$?
  local __bashlib_cl_i=${#_bashlib_cleanup[@]}

  while [ "$__bashlib_cl_i" -gt 0 ]; do
    __bashlib_cl_i=$((__bashlib_cl_i - 1))
    eval "${_bashlib_cleanup[__bashlib_cl_i]}" ||
      info "WARN: cleanup failed (exit $?): ${_bashlib_cleanup[__bashlib_cl_i]}"
  done

  exit "$__bashlib_cl_rc"
}

# shellcheck disable=SC2329  # helper is prepended into every tool; not every tool calls it
add_cleanup() {
  if [ "${#_bashlib_cleanup[@]}" -eq 0 ]; then
    trap _bashlib_run_cleanup EXIT
  fi

  _bashlib_cleanup+=("$*")
}
