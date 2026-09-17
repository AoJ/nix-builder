# Copy this directory into your own repository and adapt host.nix — it needs nothing
# from the builder's source tree.
{
  description = "A zfs host, installed by the blocks factory.";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.2605.*.tar.gz";
    builder.url = "github:AoJ/nix-builder";
  };

  outputs = { self, nixpkgs, builder }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      inherit (builder.lib.mk { inherit pkgs; }) compose;
      endpoints = compose (import ./host.nix { inherit pkgs builder; });
    in
    {
      # A zfs host has no runtime disk image (L2) — its deliverables are installers.
      packages.${system} = {
        default = endpoints.image-kexec-install.file;          # deploy kexecs this
        usb = endpoints.image-raw-install.file;                # stick -> a different disk
        inmemory = endpoints.image-raw-install-inmemory.file;  # may install its own disk
        iso = endpoints.image-iso-install.file;
      };

      # Phase 2 binds to the host's deliverable: for a zfs host that is the -install
      # artifact, and the composer picks it. The kexec tree has its own runner.
      apps.${system} = {
        personalize = {
          type = "app";
          program = pkgs.lib.getExe endpoints.image-personalize.run;
        };
        personalize-kexec = {
          type = "app";
          program = pkgs.lib.getExe endpoints.image-personalize-kexec.run;
        };
      };
    };
}
