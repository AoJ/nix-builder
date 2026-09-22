# Copy this directory into your own repository and adapt host.nix — it needs nothing
# from the builder's source tree.
{
  description = "An encrypted-zfs host, installed by the blocks factory.";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.2605.*.tar.gz";
    builder.url = "github:AoJ/nix-builder";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, builder, disko }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      endpoints = import ./host.nix {
        inherit pkgs builder;
        diskoModule = disko.nixosModules.disko;
      };
      # The SAME uniform split. This host's runtime disk images are law-forbidden (L3 — no
      # image is ever encrypted), so image-raw/image-qcow2 are STILL in packages but fail to
      # build with the L3 message (`nix build .#image-raw` tells you to use image-raw-install);
      # its real deliverables are the installers.
      d = builder.lib.deliverables { inherit pkgs endpoints; };
    in
    {
      packages.${system} = d.packages;
      apps.${system} = d.apps;
    };
}
