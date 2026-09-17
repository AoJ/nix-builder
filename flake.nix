{
  description = "Blocks: an image / install / secrets factory for NixOS hosts — evalModules blocks, a composer, and their test suite.";

  inputs = {
    # Pinned versions, moved deliberately: the suite's green is a statement about exactly
    # this world. A consumer may `follows`-override nixpkgs; its proof is then its own run
    # of the suite at that revision, not this repo's.
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.2605.1009228.tar.gz";

    # Source-only: the test hosts import disko's NixOS module by path (disko-pin.nix).
    disko = {
      url = "github:nix-community/disko/ff8702b4de27f72b4c78573dfb89ec74e36abdf1";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, disko }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      # The consumer API — `lib.mk { pkgs }` gives tools, the composer and the host-side
      # modules; `lib.extract` turns an evaluated nixosSystem into a record's variant
      # data. examples/ shows every piece in use, gated by the suite.
      lib = import ./lib/api.nix;

      # Only the mechanism contracts: cheap, host-free, safe in one evaluation. The host
      # gates and e2e are NOT checks on purpose — one eval of every host outgrows a small
      # machine, and e2e need KVM and hours. `./run-all.sh` is the suite's one entry
      # point; it discovers every target, these included.
      checks.${system} =
        import ./default.nix { inherit pkgs; }
        // { test-bash-lib = import ./lib/bash-lib-test.nix { inherit pkgs; }; };
    };
}
