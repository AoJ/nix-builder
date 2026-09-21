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
      # An unencrypted zfs host now has runtime disk images too: the format-VM makes the
      # pool from the same disko layout the install uses. The installers stay for a takeover.
      packages.${system} = {
        default = endpoints.image-raw.file;                    # bootable GPT disk, pool and all
        qcow = endpoints.image-qcow2.file;                     # the same disk, cloud envelope
        iso = endpoints.image-iso.file;                        # live medium: root in RAM
        installer = endpoints.image-kexec-install.file;        # what a deploy kexecs
        usb = endpoints.image-raw-install.file;                # stick -> a different disk
        inmemory = endpoints.image-raw-install-inmemory.file;  # may install its own disk
      };

      # The sidecars hand back the identity a consumer mounts by — no guessing a generated
      # volume id: `endpoints.image-secrets-iso.label` is the /dev/disk/by-label name, and
      # `endpoints.image-iso.label` is the runtime medium's own volume id.

      # Phase 2 fills a finished artifact's slot; the runner is OUTSIDE the store on purpose
      # (a secret in a derivation is a secret in the store):
      #   nix run .#personalize -- ./result
      apps.${system} = {
        personalize = {
          type = "app";
          program = pkgs.lib.getExe endpoints.image-personalize.run;
        };
        personalize-kexec = {
          type = "app";
          program = pkgs.lib.getExe endpoints.image-personalize-kexec.run;
        };
        secrets-sidecar-iso = {
          type = "app";
          program = pkgs.lib.getExe endpoints.image-secrets-iso.run;
        };
      };
    };
}
