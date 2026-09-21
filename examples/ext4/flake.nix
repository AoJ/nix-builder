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
    in
    {
      packages.${system} = {
        default = endpoints.image-raw.file;    # bootable GPT disk image
        qcow = endpoints.image-qcow2.file;     # the same disk in a cloud envelope
        iso = endpoints.image-iso.file;        # live medium: root in RAM
        installer = endpoints.image-kexec-install.file;  # what a deploy kexecs
      };

      # Each disk endpoint and sidecar hands back the volume identity it was stamped with,
      # so a consumer mounts by exactly what was written — no guessing a generated id:
      #   endpoints.image-secrets-vfat.label     # "SECRETS"  (mount -L SECRETS)
      #   endpoints.image-secrets-vfat.volumeId  # the FAT serial, for /dev/disk/by-uuid
      #   endpoints.image-secrets-iso.label      # the iso9660 volume id (by-label)
      #   endpoints.image-iso.label              # the live medium's own volume id
      # These are plain strings; read them wherever your deploy mounts the artifact.

      # Phase 2 and the sidecars are RUNNERS, not derivations — a secret in a derivation
      # is a secret in the store:
      #   nix run .#personalize -- ./image.raw
      apps.${system} = {
        personalize = {
          type = "app";
          program = pkgs.lib.getExe endpoints.image-personalize.run;
        };
        # The sidecar carries the same slot as a separate medium; take it as a filesystem
        # (vfat / iso) or a format you read (json). Its identity is on the endpoint above.
        secrets-sidecar = {
          type = "app";
          program = pkgs.lib.getExe endpoints.image-secrets-vfat.run;
        };
        secrets-sidecar-iso = {
          type = "app";
          program = pkgs.lib.getExe endpoints.image-secrets-iso.run;
        };
      };
    };
}
