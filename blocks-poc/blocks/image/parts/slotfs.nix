# The slot as `image` leaves it: reserved, FORMATTED, and empty. Empty keeps phase one
# cacheable and secret-free; formatted is what lets phase two refuse — a hole answers no
# question about whether the offset is right.
{ pkgs, lib, ids }:

{ name, slotName, sizeMiB }:

pkgs.runCommand "slot.img" { nativeBuildInputs = [ pkgs.dosfstools ]; }
  ''
    set -euo pipefail
    truncate -s ${toString sizeMiB}M "$out"
    mkfs.fat -n ${lib.escapeShellArg (lib.toUpper slotName)} \
      -i ${lib.escapeShellArg (ids.volumeId "${name}:slot")} "$out"
  ''
