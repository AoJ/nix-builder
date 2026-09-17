{ pkgs, tools }:

input:

(pkgs.lib.evalModules {
  specialArgs = { inherit pkgs tools; };
  modules = [ ./block.nix input ];
}).config.out
