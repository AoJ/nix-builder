let
  pkgs = import <nixpkgs> { };
in
{
  test-image = import ./blocks/image/test.nix { inherit pkgs; };
}
