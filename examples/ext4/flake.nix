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
      inherit (builder.lib.mk { inherit pkgs; }) compose;
      endpoints = compose (import ./host.nix {
        inherit pkgs builder;
        diskoModule = disko.nixosModules.disko;
      });
    in
    {
      packages.${system} = {
        default = endpoints.image-raw.file;    # bootable GPT disk image
        qcow = endpoints.image-qcow2.file;     # the same disk in a cloud envelope
        iso = endpoints.image-iso.file;        # live medium: root in RAM
        installer = endpoints.image-kexec-install.file;  # what a deploy kexecs
      };

      # Phase 2 and the sidecars are RUNNERS, not derivations — a secret in a derivation
      # is a secret in the store:
      #   nix run .#personalize -- ./image.raw
      apps.${system} = {
        personalize = {
          type = "app";
          program = pkgs.lib.getExe endpoints.image-personalize.run;
        };
        secrets-sidecar = {
          type = "app";
          program = pkgs.lib.getExe endpoints.image-secrets-vfat.run;
        };
      };
    };
}
