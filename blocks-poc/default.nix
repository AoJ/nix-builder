let
  pkgs = import <nixpkgs> { };
  tools = import ./tools { inherit pkgs; };
in
{
  test-image = import ./blocks/image/test.nix { inherit pkgs tools; };
  test-store = import ./tools/store-test.nix { inherit pkgs; };
}
