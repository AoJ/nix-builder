# The composer over ONE real host — eval-only, driven by the coverage table: every pair the
# table does not call a hole is forced to a .drv (context discarded, nothing built). The
# holes are NOT forced here — they are real derivations that fail at BUILD, so the `hole-*`
# targets build them and assert the refusal (eval cannot). Per host on purpose: one host's
# endpoints cost ~1-1.3 GB of eval heap, and five hosts in one nix process peaked at 4.7 GB
# — the OOM that kept killing this box. The gates are separate ATTRIBUTES run as separate
# nix processes (the run-all.sh pattern); evaluating them all in one eval would put the peak
# right back.
{ pkgs, compose, hosts, coverage }:

let
  inherit (pkgs) lib;

  drvOf = e: n:
    builtins.unsafeDiscardStringContext (
      if n == "closure" || n == "closure-live" then e.${n}.drvPath
      else if lib.hasPrefix "image-personalize" n || lib.hasPrefix "image-secrets" n
      then e.${n}.run.drvPath
      else e.${n}.file.drvPath);
in

h:

let
  e = compose hosts.${h};
  row = coverage.table.${h};
  holes = lib.attrNames (lib.filterAttrs (_: s: s == "hole") row);
  others = lib.subtractLists holes (lib.attrNames row);
in
pkgs.writeText "test-hosts-compose-${h}"
  (lib.concatStringsSep "\n" (map (n: "${h}.${n} ${drvOf e n}") others))
