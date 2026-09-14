let
  pkgs = import <nixpkgs> { };
  tools = import ./tools { inherit pkgs; };
  compose = import ./compose.nix { inherit pkgs tools; };
in
{
  test-image = import ./blocks/image/test.nix { inherit pkgs tools; };
  test-install = import ./blocks/install/test.nix { inherit pkgs tools; };
  test-secrets = import ./blocks/secrets/test.nix { inherit pkgs tools; };
  test-personalize = import ./blocks/personalize/test.nix { inherit pkgs tools; };
  test-store = import ./tools/store-test.nix { inherit pkgs; };
  test-compose = import ./compose-test.nix { inherit pkgs tools compose; };
}
