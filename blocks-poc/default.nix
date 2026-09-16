# Auto-callable (`nix build -f blocks-poc <attr>` and the runner), and callable by the
# flake with its own nixpkgs — the same tests either way.
{ pkgs ? import (import ../nixpkgs-pin.nix) { } }:
let
  tools = import ./tools { inherit pkgs; };
  compose = import ./compose.nix { inherit pkgs tools; };
in
{
  test-image = import ./blocks/image/test.nix { inherit pkgs tools; };
  test-install = import ./blocks/install/test.nix { inherit pkgs tools; };
  test-secrets = import ./blocks/secrets/test.nix { inherit pkgs tools; };
  test-personalize = import ./blocks/personalize/test.nix { inherit pkgs tools; };
  test-store = import ./tools/store-test.nix { inherit pkgs tools; };
  test-compose = import ./compose-test.nix { inherit pkgs tools compose; };
}
