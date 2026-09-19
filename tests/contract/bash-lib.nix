# The lib (info/error/fatal/required/run/best_effort/wait_for/retry/add_cleanup) is
# prepended into EVERY tool, so a regression here breaks all of them — this locks its
# contract (exit codes, stream separation, no temp-file leak, stdin detach, LIFO cleanup,
# errexit-suspension).
{ pkgs }:
pkgs.runCommand "test-bash-lib"
{
  nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.findutils pkgs.gnused pkgs.gnugrep ];
} ''
  set -euo pipefail
  mkdir lib
  cp ${../../lib/bash-lib.sh} lib/bash-lib.sh
  cp ${./bash-lib-test.sh} lib/bash-lib-test.sh
  bash lib/bash-lib-test.sh
  touch "$out"
''
