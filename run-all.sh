#!/usr/bin/env bash
# docs/blocks/run-all.sh — the ONE entry point for the whole blocks suite: block tests,
# eval gates, e2e. Targets are DISCOVERED from the attribute sets (the root default.nix
# and tests/default.nix), so a new test attribute is picked up with no edit here — the
# failure this runner exists to prevent is a test that exists but nothing runs.
#
# Each target runs as its own nix process (one host's eval fits this box, all of them in
# one eval do not) and e2e run with --max-jobs 1 and --cores $e2e_cores (two qemu + builds
# OOM the machine; the guest's vcpu count follows those cores through $NIX_BUILD_CORES).
# Sequential on purpose. Logs: docs/blocks/.logs/<target>.log; a PASS/FAIL summary at the
# end, exit nonzero on any failure.
#
# Usage:
#   docs/blocks/run-all.sh              # everything
#   docs/blocks/run-all.sh --list       # list targets, run nothing
#   docs/blocks/run-all.sh <filter>...  # only targets whose name contains a substring
#                                       # e.g. `run-all.sh e2e-install` or `run-all.sh gate`
set -euo pipefail

command -v nix > /dev/null 2>&1 || { echo "run-all: nix not on PATH" >&2; exit 1; }

# A cold full run builds ~15-20G of artifacts; starting under that just trades a clear
# refusal now for ENOSPC failures mid-suite.
free_kib=$(df --output=avail /nix/store | tail -1)
if [ "$free_kib" -lt $((20 * 1024 * 1024)) ]; then
  echo "run-all: only $((free_kib / 1024 / 1024))G free on /nix/store — a cold run needs ~20G;" >&2
  echo "run-all: garbage-collect first (nix-collect-garbage), or expect ENOSPC failures" >&2
fi

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$here"
logdir="$here/.logs"
mkdir -p "$logdir"

# Overridable budgets: eval-only targets are minutes, an e2e with a cold store is not.
eval_timeout="${eval_timeout:-1800}"
e2e_timeout="${e2e_timeout:-7200}"
# Cores an e2e build may use — and, THROUGH $NIX_BUILD_CORES, the guest's vcpu count
# (-smp). Two is right for this shared 6-core box (two qemu + builds OOM higher); a
# dedicated big box wants `e2e_cores=8 run-all.sh …` for a faster, wider install.
e2e_cores="${e2e_cores:-2}"

list_only=0
filters=()
for arg in "$@"; do
  case "$arg" in
    --list) list_only=1 ;;
    --*) echo "unknown flag: $arg" >&2; exit 2 ;;
    *) filters+=("$arg") ;;
  esac
done

matches() {
  [ "${#filters[@]}" -eq 0 ] && return 0
  local id="$1" f
  for f in "${filters[@]}"; do
    case "$id" in *"$f"*) return 0 ;; esac
  done
  return 1
}

# Discover targets: every attribute whose name says it is a test. The filter lives HERE
# (tests/default.nix also exports hosts and endpoints, which are inputs, not targets).
# `nix eval` hands --apply the file's value UNCALLED, so the auto-call `nix build -f`
# does for the defaulted { pkgs ? … } argument is repeated here.
discover() {
  local file="$1"
  timeout "$eval_timeout" nix eval --raw -f "$file" --apply '
    v: let set = if builtins.isFunction v then v { } else v;
    in builtins.concatStringsSep "\n" (builtins.filter
      (n: builtins.match "(test|e2e|hole)-.*" n != null)
      (builtins.attrNames set))'
}

targets=()
sc=0
root_names=$(discover .) || sc=$?
[ "$sc" = 0 ] || { echo "run-all: cannot discover root targets" >&2; exit 1; }
while IFS= read -r n; do
  targets+=(".:$n")
done <<< "$root_names"
tests_names=$(discover tests) || sc=$?
[ "$sc" = 0 ] || { echo "run-all: cannot discover tests targets" >&2; exit 1; }
while IFS= read -r n; do
  targets+=("tests:$n")
done <<< "$tests_names"
examples_names=$(discover examples) || sc=$?
[ "$sc" = 0 ] || { echo "run-all: cannot discover examples targets" >&2; exit 1; }
while IFS= read -r n; do
  targets+=("examples:$n")
done <<< "$examples_names"

if [ "$list_only" = 1 ]; then
  for t in "${targets[@]}"; do
    matches "$t" && printf '%s\n' "$t"
  done
  exit 0
fi

pass=()
fail=()
for t in "${targets[@]}"; do
  matches "$t" || continue
  dir=${t%%:*}
  attr=${t#*:}
  budget="$eval_timeout"
  jobs=()
  expect_fail=0
  case "$attr" in
    e2e-*) budget="$e2e_timeout"; jobs=(--max-jobs 1 --cores "$e2e_cores") ;;
    # A hole is a law-forbidden endpoint: its artifact MUST fail to build, with its law.
    hole-*) expect_fail=1 ;;
  esac
  echo "== $t $(date +%H:%M:%S)"
  sc=0
  timeout "$budget" nix build --no-link -f "$dir" "$attr" "${jobs[@]}" \
    > "$logdir/$attr.log" 2>&1 || sc=$?
  if [ "$expect_fail" = 1 ]; then
    # Pass ONLY on a genuine refusal: a nonzero that is not the timeout (124), and the log
    # carries our law message — a hole that builds, times out, or fails unrelatedly is broken.
    if [ "$sc" != 0 ] && [ "$sc" != 124 ] && grep -q "unsupported (" "$logdir/$attr.log"; then
      pass+=("$t")
    else
      fail+=("$t")
      echo "FAIL $t (hole did not refuse with its law; exit $sc) — log: $logdir/$attr.log"
      tail -n 20 "$logdir/$attr.log"
    fi
  elif [ "$sc" = 0 ]; then
    pass+=("$t")
  else
    fail+=("$t")
    echo "FAIL $t (exit $sc) — log: $logdir/$attr.log"
    tail -n 20 "$logdir/$attr.log"
  fi
done

echo
echo "== summary: ${#pass[@]} passed, ${#fail[@]} failed"
for t in "${fail[@]}"; do
  echo "FAIL $t"
done
[ "${#fail[@]}" -eq 0 ]
