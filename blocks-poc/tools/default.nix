{ pkgs }:

# The one privileged place: it assembles the tool set that every block is handed, and it is
# the only spot in the PoC that reaches into the repo's shared lib (mkBashTool + the bash
# helper lib it prepends). Only tools go in here. A block placed here would let a block
# reach a block, and the rule that keeps the dependency graph acyclic falls.
let
  bashTool = args: (import ../../../../lib/core/bashTool.nix) ({ inherit pkgs; } // args);
  ids = import ./ids.nix;
in
{
  inherit bashTool ids;
  fatImage = (import ./fat-image.nix { inherit pkgs bashTool; }).build;
  fatImageApp = (import ./fat-image.nix { inherit pkgs bashTool; }).app;
  gptDisk = import ./gpt-disk.nix { inherit pkgs bashTool ids; };
  store = import ./store.nix { inherit pkgs bashTool; };
  # The repo's ONE tested install action (disko-or-import -> place key -> nixos-install ->
  # clean export), consumed from its single source — no copy. The install block's installer
  # OS runs it; nothing reimplements the flow.
  niximilateInstall = import ../../../../lib/50_install/niximilateInstallApp.nix pkgs;
}
