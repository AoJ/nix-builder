# The composer over REAL hosts — eval-only, driven by the coverage table: every pair the
# table does not call a hole is forced to a .drv (context discarded, nothing built), and
# every hole is asserted to REFUSE. This is the tool against the failure that killed the
# withdrawn branch (nothing evaluated apps); it proves names, never behavior — the table
# is what says which is which.
{ pkgs, compose, hosts, coverage }:

let
  inherit (pkgs) lib;

  drvOf = e: n:
    builtins.unsafeDiscardStringContext (
      if n == "closure" || n == "closure-live" then e.${n}.drvPath
      else if lib.hasPrefix "image-personalize" n || lib.hasPrefix "image-secrets" n
      then e.${n}.run.drvPath
      else e.${n}.file.drvPath);

  refused = e: n:
    !(builtins.tryEval (
      if n == "closure" || n == "closure-live" then e.${n}.outPath
      else if lib.hasPrefix "image-personalize" n || lib.hasPrefix "image-secrets" n
      then e.${n}.run.outPath
      else e.${n}.file.outPath)).success;

  perHost = h:
    let
      e = compose hosts.${h};
      row = coverage.table.${h};
      holes = lib.attrNames (lib.filterAttrs (_: s: s == "hole") row);
      others = lib.subtractLists holes (lib.attrNames row);
      deadHoles = lib.filter (n: !refused e n) holes;
    in
    assert lib.assertMsg (deadHoles == [ ])
      "${h}: declared holes that do NOT refuse at eval: ${builtins.toJSON deadHoles}";
    map (n: "${h}.${n} ${drvOf e n}") others;
in
pkgs.writeText "test-hosts-compose"
  (lib.concatStringsSep "\n" (lib.concatMap perHost (lib.attrNames coverage.table)))
