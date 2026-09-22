# Copy this directory into your own repository and adapt host.nix — it needs nothing
# from the builder's source tree.
{
  description = "A memory-rooted appliance built by the blocks factory.";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.2605.*.tar.gz";
    builder.url = "github:AoJ/nix-builder";
  };

  outputs = { self, nixpkgs, builder }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      endpoints = import ./host.nix { inherit pkgs builder; };
      # The SAME uniform split. A squashfs appliance's INSTALLERS are holes (L6 — the image
      # writes that store, so there is nothing to install), present in holes with the law;
      # the runtime images (raw/iso/kexec) are its deliverables — the image IS the update.
      d = builder.lib.deliverables { inherit pkgs endpoints; };
    in
    {
      packages.${system} = d.packages;
      apps.${system} = d.apps;
      holes.${system} = d.holes;
    };
}
