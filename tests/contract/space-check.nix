# space-check refuses a write the filesystem cannot hold, BEFORE it starts, and names the
# shortfall; a write that fits passes. The format VM runs it ahead of the image it writes.
{ pkgs, tools }:
pkgs.runCommand "test-space-check" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
  set -euo pipefail
  ${pkgs.lib.getExe tools.spaceCheck} "$TMPDIR" 1M small.img

  sc=0
  ${pkgs.lib.getExe tools.spaceCheck} "$TMPDIR" 1P huge.img 2> err || sc=$?
  cat err >&2
  [ "$sc" -ne 0 ] || { echo "space-check let a 1P write through" >&2; exit 1; }
  grep -q "huge.img needs up to 1P" err
  grep -q "refused before writing" err

  sc=0
  ${pkgs.lib.getExe tools.spaceCheck} "$TMPDIR" lots bad.img 2> err || sc=$?
  [ "$sc" -ne 0 ] && grep -q "'lots' is not a size" err

  touch "$out"
''
