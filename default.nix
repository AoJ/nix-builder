# The contract tests: what each mechanism promises, proven without a host. Auto-callable
# (`nix build -f . <attr>` and the runner), and callable by the flake with its own
# nixpkgs — the same tests either way. The tests themselves live under tests/contract, so
# the code they check is not shelved beside them.
#
# Imported as plain paths, never as `"${dir}/file.nix"`: interpolating a directory copies
# it into the store, and the relative imports inside would then point at the store rather
# than at this tree.
{ pkgs ? import (import ./nixpkgs-pin.nix) { } }:
let
  tools = import ./tools { inherit pkgs; };
  compose = import ./compose.nix { inherit pkgs tools; };
in
{
  test-image = import ./tests/contract/image.nix { inherit pkgs tools; };
  test-install = import ./tests/contract/install.nix { inherit pkgs tools; };
  test-secrets = import ./tests/contract/secrets.nix { inherit pkgs tools; };
  test-personalize = import ./tests/contract/personalize.nix { inherit pkgs tools; };
  test-store = import ./tests/contract/store.nix { inherit pkgs tools; };
  test-compose = import ./tests/contract/compose.nix { inherit pkgs tools compose; };
  test-host-record = import ./tests/contract/host-record.nix { inherit pkgs tools; };
  test-images-for = import ./tests/contract/images-for.nix { inherit pkgs tools; };
  test-bash-lib = import ./tests/contract/bash-lib.nix { inherit pkgs; };
}
