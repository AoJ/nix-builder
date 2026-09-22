# Copy this directory into your own repository and adapt host.nix — it needs nothing
# from the builder's source tree.
{
  description = "A disk host built by the blocks factory.";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.2605.*.tar.gz";
    builder.url = "github:AoJ/nix-builder";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Optional: run the builder on YOUR nixpkgs. Its suite's green is a statement about
    # its own pin — at an overridden revision the proof is your own run of the suite.
    # builder.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, builder, disko }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      endpoints = import ./host.nix {
        inherit pkgs builder;
        diskoModule = disko.nixosModules.disko;
      };
      # The endpoint set turned into flake outputs UNIFORMLY — this host lists nothing by
      # hand. EVERY host exposes the same split, so `nix flake show` gives the whole set.
      # A pair a law forbids is still THERE, as a package that fails to build with the law
      # (a disk/ext4 host forbids none); it never vanishes and never crashes flake show.
      d = builder.lib.deliverables { inherit pkgs endpoints; };
    in
    {
      # The images under their own names — image-raw, image-qcow2, image-iso,
      # image-kexec-install, … A secret in a derivation is a secret in the store, so
      # phase 2 and the sidecars are RUNNERS in `apps`, not packages:
      #   nix build .#image-raw
      #   nix run   .#image-personalize -- ./result
      packages.${system} = d.packages;
      apps.${system} = d.apps;
    };
}
