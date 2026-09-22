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
      # hand. EVERY host exposes the same split, so `nix flake show` gives the whole set and
      # the differences show up as holes, not as names that come and go.
      d = builder.lib.deliverables { inherit pkgs endpoints; };
    in
    {
      # The buildable images under their own names — image-raw, image-qcow2, image-iso,
      # image-kexec-install, … A secret in a derivation is a secret in the store, so
      # phase 2 and the sidecars are RUNNERS in `apps`, not packages:
      #   nix build .#image-raw
      #   nix run   .#image-personalize -- ./result
      packages.${system} = d.packages;
      apps.${system} = d.apps;

      # What this host CANNOT produce, as DATA — the law and the endpoint to use instead —
      # never a crash. A disk/ext4 host has none; a zfs or squashfs host does:
      #   nix eval .#holes.x86_64-linux --json
      #   endpoints.image-raw.label / .volumeId  — mount a finished artifact by what it carries
      holes.${system} = d.holes;
    };
}
