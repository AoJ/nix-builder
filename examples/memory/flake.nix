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
    in
    {
      # The image IS the deliverable — this host has no installer at all (L6): write it
      # to the device and boot. An update ships a new image, not an install.
      packages.${system} = {
        default = endpoints.image-raw.file;     # ESP + read-only store partition
        netboot = endpoints.image-kexec.file;   # the same appliance over the network
        iso = endpoints.image-iso.file;
      };
    };
}
