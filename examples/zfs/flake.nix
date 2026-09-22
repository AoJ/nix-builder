# Copy this directory into your own repository and adapt host.nix — it needs nothing
# from the builder's source tree.
{
  description = "A zfs host built by the blocks factory.";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.2605.*.tar.gz";
    builder.url = "github:AoJ/nix-builder";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
      # The SAME uniform split as every other host — nothing hand-listed. An unencrypted zfs
      # host has real runtime images (the format-VM makes the pool from its disko layout),
      # so image-raw/image-qcow2/image-iso appear in packages next to the installers.
      d = builder.lib.deliverables { inherit pkgs endpoints; };
    in
    {
      packages.${system} = d.packages;
      apps.${system} = d.apps;
      holes.${system} = d.holes;
    };
}
