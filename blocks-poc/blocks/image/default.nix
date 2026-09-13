{ pkgs }:

input:

(pkgs.lib.evalModules {
  specialArgs = { inherit pkgs; };
  modules = [ ./block.nix input ];
}).config.out
